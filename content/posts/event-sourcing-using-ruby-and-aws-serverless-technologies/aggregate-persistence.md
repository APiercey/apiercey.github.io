---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Four: Aggregate Persistence"
date: 2023-09-28
description: How complex objects are persisted and rehydrated using the repository pattern and how guarantees are made the using Optimistic Locking strategy.
image: /images/aws-eventsourcing/aggregate-persistence.jpg
imageCredit:
  url: https://instagram.com/moabitdottir?igshid=NTc4MTIwNjQ2YQ==
  text: Facade Staircase by Moabitdottir
showTOC: true
draft: false
useComments: true
utterenceIssueNumber: 6

keywords:
  - aws
  - event sourcing
  - ruby
  - aggregates
  - persistence
  - event driven architecture
  - repository pattern
  - meta-programming
  - dynamodb
  - serverless
  - optimistic locking
  - event store

---

_This is the fourth part in an on-going blog series about [building an event sourcing system in Ruby using AWS Serverless technologies](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/introduction)._

The persistence of values and complex objects is essential to modern applications. Applications that take tremendous care of how their objects actually pass in-and-out of memory tend to perform far better than those that don't - especially in the face of changing and growing requirements.

This article covers how to implement aggregate persistence using the Repository pattern. It utilizes previously built DynamoDB table from our event store.

## Repository Class

With our event store table ready to be used, we can turn our attention towards the Class that interfaces with it: The `ShoppingCartRepo`.

### About the Repository Pattern

The repository pattern is a data abstraction pattern for _querying_ and _persisting_ objects. Its responsibility is to ensure it provides _whole_ objects when providing them and persists _all_ changes when storing them.

The Repository Pattern is often compared against the ActiveRecord pattern. The two key differences are:
- With the ActiveRecord pattern, persistence methods are implemented on the entites themselves. Entities understand and control persistence.
- With the Repository pattern, persistence is delegated to a second object called the repository, freeing entities from persistence responsibility. The repository must return a whole object with its relations. Whereas with ActiveRecord, related objects can be dynamically queried for after the initial data access.

So how is this pattern implemented? Well...

#### Impressions of How They Are Implemented

At times, the repository pattern's literature is eclectic and difficult to understand. Much of it is opinion-based and often handed down from one generation of engineering teams to another. 

Therefore, it's imperative for us to get on the same page about what it means for us.

I quite enjoy the way Vaugn Vernon summarizes Repositores in his book, [_Implementing Domain Driven Design_](https://www.oreilly.com/library/view/implementing-domain-driven-design/9780133039900/), also known as _'The Red Book'_, which I'll paraphrase:

> There are two kinds of repositories. The first acts as a collection and provides an interface for accessing entities as if they were already loaded in-memory. Changed entities are persisted by passing them to a `save` method. The second type offers only two methods: fetch and store, which fetch and persist single changed entities.

A helpful way to look at this is, there are two types of Repository patterns:
- One that is really effective at meeting complex querying needs. This is highly suited to the Q in CQRS.
- One that is really effective at building and saving a single complex object. This is highly suited to the C in CQRS.

For accessing our aggregates, we will employ the latter definition.

![Repository returns an aggregate](/images/aws-eventsourcing/repo-returning-agg.jpg)

In large applications that deal with increasingly diverse read and write operations, it is common to have two sets of Repository objects that implement this pattern. Often, a collection-like repository will implement only an interface for intended queries which delegate to `Query` classes.

### Repository Outline

Our repository will have only two methods: `fetch` and `store`, where fetch accepts a single `uuid` and `store` accepts an entire aggregate.

Additionally, our repository will require access to DynamoDB. This will be injected as a dependency.

```ruby
class ShoppingCartRepo
  def initialize(dynamodb_client)
    @dynamodb_client = client
  end

  def fetch(uuid)
    # Will implement
  end

  def store(shopping_cart)
    # Will implement
  end
end
```

### Store Method

Before we can `fetch` we must be able to `store`.

The `store` method has three responsibilities:
- Persisting new events (changes) queued in the aggregate.
- Provide optimistic locking (prevent change collisions).
- Clearing persisted events and returning a clean aggregate, ready for further interactions. 


When persisting changes, each change will be persisted as a unique record in our DynamoDB table. Record uniqueness is guaranteed by two DynamoDB table attributes:
- The AggregateUuid, which is the _hash_ key.
- The Version, which is the _range_ key.

Plus, `Version` is the attribute providing optimistic locking. We'll see how this is achieved later.

#### Persistence

Our `store` method.

```ruby
class ShoppingCartRepo
  # ...
  def store(shopping_cart)
    new_version = shopping_cart.version # Will be added below

    new_events = shopping_cart.changes.map do |event|
      new_version = new_version + 1 # New version for each event

      {
        EventUuid: SecureRandom.uuid,
        AggregateUuid: shopping_cart.uuid,
        Name: event.class::NAME,
        Data: event.to_h,
        Version: new_version
      }
    end

    put_operations = events.map do |event|
      {
        put: {
          item: event,
          table_name: "scd-es-table",
          condition_expression: "attribute_not_exists(#v)", # Provides optimistic locking
          expression_attribute_names: {
            "#v" => "Version"
          }
        }
      }
    end

    @dynamodb_client.transact_write_items({transact_items: put_operations})

    shopping_cart.clear_changes
    shopping_cart.version = new_version
    shopping_cart
  end
end
```

Firstly, we transform newly published events into a collection of hashes that will be stored as data. Part of this transformation is providing an incremented version for individual events.

The starting event number must come from the supplied aggregate. So we'll add this functionality to the `Aggregate` module. As we'll see later, the `fetch` method sets the aggregate version..

```ruby
module Aggregate
  # ...
  def version
    @version || 0
  end

  def version=(new_version)
    @version = new_version.to_i
  end
  # ...
end
```

With DynamoDB, you may persist multiple changes in a transaction similar to relational databases. However, we must describe all operations and execute them in a single call.

Part of transforming events is transforming the actual event data into a structure suited to persistence. DynamoDB is a document store, so it handles Hashes just fine.

In order to accomplish this, our events must implement the `to_h` method.

```ruby
class CartOpened
  attr_reader :shopping_cart_uuid
  
  # ...

  def to_h
    { shopping_cart_uuid: @shopping_cart_uuid }
  end
end

class ItemAdded
  attr_reader :shopping_cart_uuid, :item_name
  
  # ...

  def to_h
    { shopping_cart_uuid: @shopping_cart_uuid, item_name: @item_name }
  end
end
```

Finally, `store` executes the transaction and persists all changes as records. 

#### Providing Optimistic Locking

In my personal opinion, this is the most integral responsibility of a repository object - to prevent data collisions.

[Optimistic Locking](https://stackoverflow.com/questions/129329/optimistic-vs-pessimistic-locking) is a kind of application level lock. Before changing a table record, an application reads the record from the database and keeps note of the `version` columns value.

During the data update phase, the application will abort the transaction if the `version` values are not the same. This prevents having to create table or records locks in the database.

Normally, in DynamodDB tables, if a record with a matching hash and range pair already exists it is overwritten entirely. With `conditional_expressions`, it alters this behaviour to throw an [exception](https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Errors/TransactionCanceledException.html).

Here is a jist from above.

```ruby
{
  # ...
  condition_expression: "attribute_not_exists(#v)", 
  expression_attribute_names: {
    "#v" => "Version"
  }
  # ... 
}
```


Our `conditional_expression` works by using a [DynamoDB function](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.OperatorsAndFunctions.html) called `attribute_not_exists` which only allows the expression to be committed if it evaluates to `true`. In our case, the expression allows commits to occur if the `Version` does not already exist. 

One critical detail to remember, `Version` is a _range_ field. Its value is only unique within its own _range_ for the entitie's _hash_ (`AggregateUuid`).

##### A Quick Example
Consider the following table:

| AggregateUuid | Version |
|---------------|---------|
| uuid-1        | 1       |
| uuid-1        | 2       |
| uuid-2        | 1       |
<pre></pre>

There are three events for two seperate aggregates.

An attempt to insert another event with the `AggregateUuid` equal to `uuid-1` and `Version` of `2` would result in an exception because the ranged value of `Version` already exists.

On the otherhand, an attempt to insert another event with the `AggregateUuid` equal to `uuid-2` and `Version` of `2` would be successful.

#### Clearing Changes

Lastly, our `store` method needs to clear persisted events on the Aggregate. We can achieve this by implementing a method in the `Aggregate` module.

```ruby
module Aggregate
  # ...

  def clear_changes
    @changes = []

    self
  end
  
  # ...
end
```

Our `store` method is complete and our aggregates can now be stored! Congratulations!

### Fetch Method
The best for last! First, let's discuss how aggregates are initialized. 

#### Preparing our Aggregate Module

Currently, to instantiate our ShoppingCart, we must provide a `uuid`.

```ruby

class ShoppingCart
  include Aggregate

  attr_reader :items

  def initialize(uuid)
    @items = []

    enqueue(CartOpened.new(uuid))
  end
  
  # ...
end
```

What about when we need to _rehydrate_ an aggregate? We cannot instantiate an empty aggregate without enqueuing a "start" event - in our case, a `CartOpened`. There are several options.

We could move the responsibilities of _building_ a ShoppingCart to a `build` method. This will instantiate the aggragate and `apply` the starting correct event but there are some drawbacks. We now have _two_ methods for instantiating objects and it can be confusing which one to use, especially as more engineers join the project.

We could move the responsibility of instantiating a `ShoppingCart` aggregate and `CartOpened` event to the repository. This is where an aggregate is instantiated and the `CartOpened` starting event is applied. This too has some drawbacks. For one, the _event_ which belongs to the domain model is now part of the repository! The model has very limited control over when these events become applied. No bueno!

I'm sure there are other clever ways to do this in Ruby. However, there is one pragmatic way I've come to enjoy: nullifying arguments.

When instantiating an aggregate, we can pass in a `uuid` as `nil`. By doing so, the aggregate decides wether to enqueue a starting event or not. The aggregate retains control of when events are published and keeps a single method for instantiating aggregates.

We'll apply this principle to the `ShoppingCart` aggregate.

```ruby
class ShoppingCart
  include Aggregate

  attr_reader :items

  def initialize(uuid = nil) # uuid is allowed to be nil
    @items = []

    enqueue(CartOpened.new(uuid)) unless uuid.nil? # if it's new, it's a blank object
  end

  def add_item(item_name)
    enqueue(Events::ItemAdded.new(uuid, item_name))
  end

  on CartOpened do |event|
    @uuid = event.shopping_cart_uuid
  end

  on ItemAdded do |event|
    @items = @items.append(event.item_name)
  end
end
```

In a way, I find similarities to the [`Null-Object` pattern](https://en.wikipedia.org/wiki/Null_object_pattern).

#### Implementing `fetch`

The `fetch` method has three responsibilities:
- Query for a range of previous events using a `uuid` and apply them against an aggregate.
- Ensure the latest version is set.
- If no events can be found _or_ the `uuid` is _`nil`_, return `nil`.

```ruby
class ShoppingCartRepo
  def initialize(dynamodb_client)
    @dynamodb_client = dynamodb_client
  end
  
  def fetch(uuid)
    shopping_cart = ShoppingCart.new

    events = fetch_aggregate_events(uuid)

    return nil if events.empty?

    shopping_cart.version = events.last.fetch("Version").to_i

    events
      .map { |event| build_event(event) }
      .reject(&:nil?)
      .each { |event| shopping_cart.apply(event) }

    if shopping_cart.uuid.nil?
      nil
    else
      shopping_cart
    end
  end

  private

  def fetch_aggregate_events(aggregate_uuid)
    query_options = {
      table_name: "scd-es-table",
      key_condition_expression: "AggregateUuid = :aggregate_uuid",
      expression_attribute_values: {
        ":aggregate_uuid" => aggregate_uuid,
      },
      consistent_read: true
    }

    items = []

    result = @dynamodb_client.query(query_options)

    loop do
      items << result.items

      break unless (last_evaluated_key = result.last_evaluated_key)

      result = @dynamodb_client.query(query_options.merge(exclusive_start_key: last_evaluated_key))
    end

    items.flatten
  end
  
  def build_event(raw_event)
    name = raw_event.fetch('Name')
    data = raw_event.fetch('Data')
      
    case name
    when "CartOpened"
      Events::CartOpened.new(data.fetch("shopping_cart_uuid"))
    when "ItemAdded"
      Events::ItemAdded.new(data.fetch("shopping_cart_uuid"), data.fetch("item_name"))
    when "CartClosed"
      Events::CartClosed.new(data.fetch("shopping_cart_uuid"))
    else
      nil
    end
  end
  
  # ...
end
```

Our new `fetch` starts be instantiating a blank `ShoppingCart` by passing in `nil` as the `uuid`. This means the aggregate has not applied a `CartOpened` event. Afterwords, events are queried from DynamoDB using a the `key_condition_expression`.

In order to ensure we are querying all available records, we must paginate over the evaluation set. 

If it _cannot_ find any events, it returns `nil` rather than an aggregate. Otherwise, it loops over each record, first _initializing_ an event and then _applying_ it against the aggregate.

At the end, if the `uuid` of the aggregate is not `nil`, the rehdrated `ShoppingCart` is returned. Otherwise, `nil`. 

#### When would `uuid` be nil?

If our query returns a collection of events and our starting event _always_ provides a `uuid`, when would it be `nil`?

One of the core aspects of event sourcing is that events are **never** deleted nor altered. The event store is append-only and the events themselves are immutable! This begs the question, how are aggregates "deleted"?

By another event of course! In eventually consistent systems, an event that signifies the end of an object's life is called a [Tombstone](https://en.wikipedia.org/wiki/Tombstone_(data_store)). The motivation section in the Wikipedia entry describes this as (emphasis mine),

> If information is deleted in an eventually-consistent distributed data store, the "eventual" part of the eventual consistency causes the information to ooze through the node structure, **where some nodes may be unavailable at time of deletion**. But a feature of eventual consistency causes a problem in case of deletion, as a node that was unavailable at that time will try to "update" the other nodes that no longer have the deleted entry, assuming that they have missed an insert of information. Therefore, **instead of deleting the information, the distributed data store creates a (usually temporary) tombstone record**, which is not returned in response to requests.

When our aggregate should be deleted, another event is enqueued which sets the `uuid` to `nil` effectively deleting it. Eventually, downstream consumers will receive this event and decide what a tombstone means for their domain.

Consider the diagram below.

![Tombstone Events](/images/aws-eventsourcing/tombstone-events.jpg)

In this application, there exists an Ordering System which produces events into a stream. In this particular frame in time, a series of events have occurred which signal the creation of an object through a starting event and the deletion of an object through a tombstone event.

The Ordering System is immediately consistent, so it knows that data has been deleted. Downstream System A has already processed all events that have occurred in the event stream and knows that data has been deleted as well.

However at the same time, Downstream System B is about to discover that data has been deleted from the Ordering System. While Downstream System C hasn't even known the data existed in the first place.

In our `ShoppingCart`, we can define this behaviour with a `CartClosed` event.

```ruby
class ShoppingCart
  # ...
  
  def close
    enqueue(CartClosed.new(uuid))
  end

  on CartClosed do |event|
    @uuid = nil
  end
  
  # ...
end
```

Whenever a closed (deleted) `ShoppingCart` is rehydrated, the final event will be `CartClosed`. This will prevent the aggregate from being returned.

## Small Cleanup

Our repository looks good but it's breaking a few SOLID rules. If we carefully read through its code, two things stand out:
- There is a wide array of responsibilities in a single class.
- Aside from the events, there is hardly anything about this implementation that seems `ShoppingCart` specific. 

We can make this far better.

### Refactoring

We'll refactor our `ShoppingCartRepo` to abstract persistence behaviours into a base class. Our goal is to accomplish two objectives:
- All aggregate repositories inherit from the same base class and behave the same way.
- To create a code that is easier to maintain, it is desirable to separate concerns.

Martin Fowler's _[Refactoring](https://martinfowler.com/books/refactoring.html)_ describes a comprehensive set of refactoring approaches. We'll apply a few here.

#### EventBuilder Class

Our repository does not need to understand how events are built. It may delegate this to a second class. Using the _[Extract Class](https://refactoring.com/catalog/extractClass.html)_ refactoring, we'll extract this behaviour to its own class and inject it as a dependency.

```ruby
module Events
  class Builder
    def build(name, data)
      case name
      when "CartOpened"
        CartOpened.new(data.fetch("shopping_cart_uuid"))
      when "ItemAdded"
        ItemAdded.new(data.fetch("shopping_cart_uuid"), data.fetch("item_name"))
      else
        nil
      end
    end
  end
end
```

Injecting the new class as a dependency and replacing the existing build implementation with a call to the `event_builder` object.

```ruby
class ShoppingCartRepo
  def initialize(dynamodb_client, event_builder)
    @dynamodb_client = client
    @event_builder = event_builder # New event builder class
  end
  
  # ... fetch and store
  
  def build_event(raw_event)
    event_builder_module.build(raw_event.fetch('Name'), raw_event.fetch('Data'))
  end
end
```

#### Tailored DynamoDB Client

The repository is responsible for both accessing the underlying persistence technology and building an aggregate. Let's separate this.

First, we'll use _[Extract Function](https://refactoring.com/catalog/extractFunction.html)_ refactoring to move data persistence from `store` into its own method.

```ruby
class ShoppingCartRepo
  # ...
  
  def store(shopping_cart)
    new_version = shopping_cart.version # Will be added below

    new_events = shopping_cart.changes.map do |event|
      new_version = new_version + 1 # New version for each event

      {
        EventUuid: SecureRandom.uuid,
        AggregateUuid: shopping_cart.uuid,
        Name: event.class::NAME,
        Data: event.to_h,
        Version: new_version
      }
    end

    insert_aggregate_events!(new_events) # Call new method

    shopping_cart.clear_changes
    shopping_cart.version = new_version
    shopping_cart
  end
  
  private
  
  def insert_aggregate_events!(events)
    put_operations = events.map do |event|
      {
        put: {
          item: event,
          table_name: "scd-es-table",
          condition_expression: "attribute_not_exists(#v)",
          expression_attribute_names: {
            "#v" => "Version"
          }
        }
      }
    end

    @dynamodb_client.transact_write_items({transact_items: put_operations})

    nil
  end
end
```

Next, we'll use _Extract Class_ refactoring once again to move data access into its own class. Luckily for us, _querying_ events is already isolated into its own method.

```ruby
class EsDynamoTableClient
  def initialize(dynamodb_client, table_name)
    @dynamodb_client = dynamodb_client
    @table_name = table_name
  end

  def fetch_aggregate_events(aggregate_uuid)
    query_options = {
      table_name: @table_name,
      key_condition_expression: "AggregateUuid = :aggregate_uuid",
      expression_attribute_values: {
        ":aggregate_uuid" => aggregate_uuid,
      },
      consistent_read: true
    }

    items = []

    result = @dynamodb_client.query(query_options)

    loop do
      items << result.items

      break unless (last_evaluated_key = result.last_evaluated_key)

      result = @dynamodb_client.query(query_options.merge(exclusive_start_key: last_evaluated_key))
    end

    items.flatten
  end

  def insert_aggregate_events!(events)
    put_operations = events.map do |event|
      {
        put: {
          item: event,
          table_name: @table_name,
          condition_expression: "attribute_not_exists(#v)",
          expression_attribute_names: {
            "#v" => "Version"
          }
        }
      }
    end

    @dynamodb_client.transact_write_items({transact_items: put_operations})

    nil
  end
end
```

Now, our `ShoppingCartRepo` looks much simpler.

```ruby
class ShoppingCartRepo
  def initialize(dynamodb_client, event_builder)
    @dynamodb_client = dynamodb_client
    @event_builder = event_builder
  end
  
  def fetch(uuid)
    shopping_cart = ShoppingCart.new

    events = @dynamodb_client.fetch_aggregate_events(uuid) # We call the new class explicitly

    return nil if events.empty?

    shopping_cart.version = events.last.fetch("Version").to_i

    events
      .map { |event| build_event(event) }
      .reject(&:nil?)
      .each { |event| shopping_cart.apply(event) }

    if shopping_cart.uuid.nil?
      nil
    else
      shopping_cart
    end
  end
  
  def store(shopping_cart)
    new_version = shopping_cart.version 

    new_events = shopping_cart.changes.map do |event|
      new_version = new_version + 1 

      {
        EventUuid: SecureRandom.uuid,
        AggregateUuid: shopping_cart.uuid,
        Name: event.class::NAME,
        Data: event.to_h,
        Version: new_version
      }
    end

    @dynamodb_client.insert_aggregate_events!(new_events) # We call the new class explicitly

    shopping_cart.clear_changes
    shopping_cart.version = new_version
    shopping_cart
  end
  
  # ...
end
```

#### DynamoDBRepo Parent Class

Future aggregate repos will benefit from an existing class which implements aggregate rehydration and persistence behaviours.

First, we'll define our parent class and inherit it from the `ShoppingCartRepo` class.

```ruby
class DynamoDBRepo
  def initialize(dynamodb_client)
    @dynamodb_client = dynamodb_client
  end
end

class ShoppingCartRepo < DynamoDBRepo
  # ...
end
```

Then, using the _[Pull Up Method](https://refactoring.com/catalog/pullUpMethod.html)_ refactoring, we'll move `fetch` and `store` into the parent class.


```ruby
class DynamoDBRepo
  def initialize(dynamodb_client, event_builder)
    @dynamodb_client = dynamodb_client
    @event_builder = event_builder
  end
  
  def fetch(uuid)
    shopping_cart = ShoppingCart.new

    events = @dynamodb_client.fetch_aggregate_events(uuid) # We call the new class explicitly

    return nil if events.empty?

    shopping_cart.version = events.last.fetch("Version").to_i

    events
      .map { |event| build_event(event) }
      .reject(&:nil?)
      .each { |event| shopping_cart.apply(event) }

    if shopping_cart.uuid.nil?
      nil
    else
      shopping_cart
    end
  end
  
  def store(shopping_cart)
    new_version = shopping_cart.version 

    new_events = shopping_cart.changes.map do |event|
      new_version = new_version + 1 

      {
        EventUuid: SecureRandom.uuid,
        AggregateUuid: shopping_cart.uuid,
        Name: event.class::NAME,
        Data: event.to_h,
        Version: new_version
      }
    end
  end
end

class ShoppingCartRepo < DynamoDBRepo
  # Now an EmptyClass
end
```

There is one last alteration to make. `DynamoDBRepo` class still references the `ShoppingCart` aggregate.

We can fix this with meta-programming by making the `ShoppingCart` class tell its parent what sort of aggregate it needs.

```ruby
class DynamoDBRepo
  class AggregateClassUndefined < StandardError
    def message
      "Aggregate class is not defined"
    end
  end
  
  @aggregate_class = nil
  
  def initialize(dynamodb_client, event_builder)
    @dynamodb_client = dynamodb_client
    @event_builder = event_builder
    
    raise AggregateClassUndefined if aggregate_class.nil?
  end
  
  def self.aggregate(aggregate_class)
    @aggregate_class = aggregate_class
  end

  def self.aggregate_class
    @aggregate_class
  end
  
  # ...
  
  private
  
  def aggregate_class
    self.class.aggregate_class
  end

  def event_builder_module
    self.class.event_builder_module
  end
end
```

Our repository can now be configured by specifying that it should be used to store and build aggregates for ShoppingCart.

```ruby
class ShoppingCartRepo < DynamoDBRepo
  aggregate ShoppingCart
end
```

Personally, I believe the same behaviour should be used for the `EventBuilder` class as well.

By using the _[Pull Down Field](https://refactoring.com/catalog/pushDownField.html)_ refactoring, we can achieve the same result. I'll omit the details from here, as we'll conclude with a breif overview shortly.

```ruby
class ShoppingCartRepo < DynamoDBRepo
  aggregate ShoppingCart
  event_builder Events::Builder
end
```

### Refactoring Conclusion

This type of refactoring makes small adjustments that improve a problematic area of code over time. It favors small consistent wins over large - and potentially dangerous - restructurings.

Quite a few changes were presented with omitted code blocks. For a full capture of the `ShoppingCartRepo`, `DynamoDBRepo`, and `EsDynamoTableClient` classes, you may view them on this [GitHub Gist](https://gist.github.com/APiercey/2960739a7ec3bd2bfdfdc4cc557d42d6).

## Test Run

Let's take our repository for a spin.

```ruby
require 'aws-sdk-dynamodb'

# DynamoDB Client
dynamo_db_client = EsDynamoTableClient.new(Aws::DynamoDB::Client.new, "scd-es-table")

# ShoppingCartRepo
shopping_cart_repo = ShoppingCartRepo.new(dynamo_db_client)
  
shopping_cart = ShoppingCart.new("test-uuid")

shopping_cart.add_item("apiercey.github.io subscription")

# There should now be two events in @changes

puts shopping_cart.inspect

shopping_cart_repo.store(shopping_cart)
```

Taking a peek into our DynamoDB table, we see the record there, with the set of changes as events.

![Inspecting dynamodb](/images/aws-eventsourcing/inspect-dynamo-db.png)

We can fetch the same shopping cart and inspect its state.
```ruby
rehydrated_shopping_cart = shopping_cart_repo.fetch("test-uuid")

rehydrated_shopping_cart.inspect
```

`inspect`ing the object should show us a complete `ShoppingCart` with a `uuid` and an `item`.

![Inspecting shopping cart](/images/aws-eventsourcing/inspect-shopping-cart.png)

## Conclusion

We've brought our aggregates full circle and can now create and rehydrate them for future use. We've done this by leveraging our DynamoDB table and the repository pattern.

Most importantly, we discovered how change collisions can be prevented using the Optimistic Locking strategy and why it's so crucial to do so.

Additionally, we saw how we could refactor complex classes to gradually become more simple.

The full code for part three of our event sourcing application can be found here: https://github.com/APiercey/aws-serverless-event-sourcing/tree/part-four-aggregate-persistence

Next, we will take the first step into building event handlers for these events using _Change Data Capture_. We'll accomplish this using DynamoDB Streams, Lambda, and Kinesis!
