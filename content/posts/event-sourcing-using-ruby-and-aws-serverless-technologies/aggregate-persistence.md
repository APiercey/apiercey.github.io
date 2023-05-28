---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Three: Aggregate Persistence"
date: 2023-03-06
description: How complex objects are persisted and how we can tame object complexity by refactoring.
image: images/event-sourcing.jpg
showTOC: true
draft: false
list: "never"
useComments: true
disqusIdentifier: "jzvl7n37kAl7l"

---

This is part three of an ongoing series where we build an EventSourced system in Ruby using AWS Serverless Technologies.

We're going to implement aggregate persistence by using the Repository pattern and DynamoDB.

We will start by designing our event store and building the first component - the events table.

## Designing an Event Store

An event store is the database in an event sourced system. It allows querying and persisting events and is the single source of truth for system data.

While an event store may be implemented with many different technologies it should meet 4 key criteria:
- The ability to persist ordered events.
- The ability to fetch a range of events (or all events).
- The ability to push events to downstream listeners.
- The ability to prevent conflicting changes from happening at the same time.

Our event store will be implemented using DynamoDB, Lambda, and Kinesis. Let's review each criteria in turn.

### The Ability to Persist Ordered Events

Event ordering is paramount for event sourced aggregates. Aggregate events which are out of order can have diasterous effects. 

For example, in accounting systems, accounts which are overdrawn (have negative funds) are usually subject to fixed fees regardless of the time span they are overdrawn.

Let's say Bob deposits 100 dollars into his account on Monday and withdraws 50 dollars on Tuesday. This means there are two events stored in the event store:
- FundsWithdrawn: $100 on Monday
- FundsDeposited: $50 on Tuesday

If the downstream application responsible for applying overdrawn fees were to receive the FundsDeposited event first before the FundsWithdrawn, poor Bob loss money (and the customer support member receiving a not-so-fun phone call)!

### The Ability to Fetch a Range of Events

A flexible event store allows fetching events from any given time range. Traditionally, when using an event store to rehydrate an aggregate, all events are fetched to build up the state. Expressed as _`[first..last]`_

However, some aggregates may be more popular than others and outside it's normal lifecycle. In such cases, these aggregates may have hundreds of events and rehydration takes substantially longer than normal and consume far greater amounts of memory.

Through a process called _snapshoting_ an aggregate's complete state may be persisted as an event. From there, only a range starting from the _last_ snapshot till the latest event is necessary. Expressed as _`[n..last]`_

Finally, in some cases a historical range needs to be examined. Expressed as _`[a..b]`_.

There are two common cases for this:
- An audit or inspection question is posed, "When did _x_ happen to Aggregate _y_?".
- A report must be composed. A range of can be replayed, building up report information.

Snapshoting is outside the scope of this series, however, as it comes with it's own set of challenges. It's important to be aware of the pattern in case you are experiencing this problem.

### The Ability to Push Events to Downstream Listeners

TODO: Insert link

In the first article, one of the primary reasons for introducing eventsourcing is to provide stronger gaurantees when informing interested parties about data changes. Therefore, this requirement falls under within the circle of responsibility of the event store.

An event store which does not provide this functionality may still be used but the burden falls on either the engineer utilizing the event store to provide a mechanism of informing interested parties or said parties must periodically query the event store looking for new events.

### The Ability to Prevent Conflicting Changes From Happening at the Same Time

Consider two requests entering a system at the same time, requesting to change a person's name.

1. Request One opens a transaction.
2. Request Two opens a transaction.
3. Request One changes the person's name to "Alex"
4. Request Two changes the person's name to "Alexander"
5. Request Two commits the transaction.
6. Request One commits the transaction.

Request two, despite starting last beats request one to the punch. The user of this software would left confused to why their name is not as expected.

In a more series scenario, such as moving money between accounts, the risk can be much higher. A well produced event store prevents such scenarios from transpiring.

The most accepted approach a strategy known as Optimistic Locking. We'll discuss this in detail within this article.

### Design Overview

Our event store will utilize four AWS technologies to meet the key criteria:

- DynamoDB to store our aggregate events and provide optimistic locking. This will act as a hot storage.
- Kinesis Streams to push events to our to interested parties.
- S3 Bucket to store our events for long term storage. This will act as a cold storage.
- Two Lambdas:
  - The first to capture new events added to our DynamoDB table and push them to our Kinesis Stream. This will act as an event publisher.
  - The second to subscribe to the Kinesis stream and record events to the cold storage (S3 Bucket).

![Event Store](/images/aws-eventsourcing/eventstore-design.jpg)

#### Hot vs Cold Storage

The hot event storage provides immediate access to events and allows insertion of new events under optimic locking. There, gaurantees are made about the data being inserted into the store. Any events added here gain immediate consistency.

Reading these events must be fast and in tune with the non-functional _Write_ requirements of our store.

On the opposite side, cold event storage provides infrequent access more aligned with non-function _Read_ requirements of our store.

There, large batches of events can be readwithout impacting performance on the write side of our store and subjecting ourselves to large overhead costs.

For example, with tools such as [Athena](https://aws.amazon.com/athena/), it's possible to query our events using SQL to build reports or derive business insights.

## DynamoDB Events Table

DynamoDB is serverless Document DB from AWS which scales according to demand. Unlike traditional databases technologies where each table belongs to a specific databases, a DynamoDB table do not belong to any overarching entity.

To implement a table, it requires only a few things:
- A tablename
- A primary key, called the hash key. Must be unique.
- And optionally, a range key, which when used acts as a second lookup key. Must be unique only for it's primary key.

The primary key will act as the the lookup key for the value. It's possible to provide additional lookup keys, called Global or Local Secondaries, but they won't be necessary for our implementation.

Our first piece of Infrastructure as Code will be our table. We'll define both the table and a `event_store` module for future components.

### Defining the Module

Firstly, we'll need to setup our infrastructure directory to use the AWS platform.

```bash
# cd to an empty directory you choose
touch providers.tf
```
```terraform
provider "aws" {
  version = "~> 4.57" # Version used at the time of writing
  region  = "us-east-1" # Change this if you wish
}
```

Next, the event store. A Terraform module is simply a directory.

```bash
mkdir event_store

touch event_store/variables.tf
touch event_store/outputs.tf
```

Our event store will require a name, which we can supply as a variable.

```terraform
# event_store/variables.tf

variable "name" {
  type = string
}
```

Next, we'll define our events table.

```bash
touch event_store/dynamodb.tf
```

The hash key (primary key) will be named `AggregateUuid` and act store out aggregate's identifier.

We'll also include a range key named `Version`. Versions are used to facilitate Optimistic Locking. We'll dive into that more later. Unfortunately, due to a flaw in DynamoDB we must provide range keys upfront if we wish to use them.

```terraform
# event_store/dynamodb.tf

resource "aws_dynamodb_table" "es_table" {
  name     = "${var.name}-es-table" # Note the variable here
  hash_key = "AggregateUuid"
  range_key = "Version"

  attribute {
    name = "AggregateUuid"
    type = "S"
  }

  attribute {
    name = "Version"
    type = "N"
  }

  # For testing purposes, these values will do just fine
  read_capacity = 1
  write_capacity = 1
}
```

### Using the Module

Now our module is ready to be used, let's define the module in our infrastructure directory.

```bash
touch event_store.tf
```

```terraform
# event_store.tf

module "event-store" { # May be whatever name you choose. Must be unique.
  source = "./event_store" # points to a directory

  name = "scd"
}
```

Our `event-store` module sources the previously defined custom module. By doing so, it will build all infrastructure resources defined within that module and treat them as a group.

We can build our infrastructure by running terraform apply.

```bash
$ terraform apply
```

Logging into AWS and looking at DynamoDB, we can see our table. One really great feature of DynamoDB is you can inspect tables and their items from the console which makes debugging a charm.

![Events Table](/images/aws-eventsourcing/dynamodb-scd.png)

Additional event store components will be added in future articles.

## Repository Class

With our event store table ready to be used, we can turn our attention towards the Class that interfaces with it: The `ShoppingCartRepo`.

### About the Repository Pattern

The repository pattern is a data abstraction pattern for _querying_ and _persisting_ objects. It's responsibility is to ensure it provides _whole_ objects when providing them and persisting _all_ changes when storing them.

Often, Repository Pattern is compared against the ActiveRecord pattern. The two key differences are:
- With the ActiveRecord pattern, persistence methods are implemented on the Entites themselves. Entities understand and are responsible for persistence.
- With the Repository pattern, persistence is delegated to a second object - being the repository. Entities are releieved of persistence responsibilities. Entire objects and their relations _must_ be provided. Where as with ActiveRecord, related objects can be dynamically queried for after the initial data access.

So how is this pattern implemented? Well...

#### Impressions of How They Are Implemented

The literature around the repository pattern can be eclectic and at times difficult to understand. Much of it is opinion based often handed down, from one generation of engineering teams to another. 

Therefore, it's important for us to get on the same page of what works for us / important for us. (decide which to us)

I quite enjoy the way Vaugn Vernon summaries Repositores in his book, [_Implementing Domain Driven Design_](https://www.oreilly.com/library/view/implementing-domain-driven-design/9780133039900/), also known as _'The Red Book'_, which I'll paraphrase:

> There are two kinds of repositories. The first, acts as a collection and provides an interface for accessing entities as if they were already loaded in-memory. Changed entities are persisted by passing them to a `save` method. The second kind, provides only two methods: `fetch` and `store`, which fetch and persist single changed Entities respectfully.

A nice way to look at this is, there are two types of Repository patterns:
- One which is _really_ great at meeting complex querying needs. This is highly suited for the **Q** in CQRS.
- One which is _really_ great at building and saving a single complex object. This is highly suited for the **C** in CQRS.

For accessing our aggregates, we will employ the later definition.

In large applications that deal with incresingly different read and write operations, it is common to have two sets of Repository objects that implement this pattern. Often, a collection-like repository will implement only an interface of intended queries which delegate to `Query` classes.

### Repository Outline

Our Repository will have only two methods: `fetch` and `store`, where fetch accepts a single `uuid` and `store` accepts an entire Aggregate.

Additionally, our Repository will require access to DynamoDB. This will be injected as a dependency.

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
- Persisting new events (changes) that are queued in the aggregate.
- Provide optimistic locking (prevent change collision).
- Clearing persisted events and returning a clean aggregate, ready for further interactions. 


When persisting changes, each change will be persisted as a unique record in our DynamoDB table. Record uniqueness is gauranteed with two attributes:
- The AggregateUuid, which is the _hash_ key.
- The Version, which is the _range_ key.

Plus, the `Version` is the attribute which provides optimistic locking. We'll see how this is achieved later.

#### Persistence

Our store method.

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

Firstly, we transform new events into a collection of hashes that will be stored as data. Part of this transformation is providing a new version for individual events.

The starting event number must come from the aggregate. So we'll add this functionality now to our `Aggregate` module. As we'll see later, the `fetch` method will set the aggregate version.

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

Part of transforming events is transforming the actual event data into a structure suited for persistence. DynamoDB is a document store, so it handles Hashes just fine.

In order to accomplish this, our events must implement a `to_h` method.

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

In my personal opinion, this is the most integral responsibility of a Repository object - to prevent data collisions.

Normally, in DynamodDB Tables, if a unique record already exists it is overwritten entirely. With `conditional_expressions`, it alters this behaviour to through an [exception](https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Errors/TransactionCanceledException.html).

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


Our `conditional_expression` works by using a [DynamoDB function](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.OperatorsAndFunctions.html) called `attribute_not_exists` which only allows the expression to be committed if it evalues to `true` and in our case, the expression allows commits if the `Version` does not already exist. 

With one important detail to remember, `Version` is a _range_ field. It is only unique for it's given _range_ (`AggregateUuid`).

#### Clearing Changes

Lastly, our `store` method needs to clear the persisted events. We can achieve this by implementing a method to do so in the `Aggregate` module.

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

Our `store` method is complete and our Aggregates can now be persisted! Congratulations!

### Fetch Method
The best for last! With everything we've build up until now, this is by far the easiest.

But first, let's talk about how our Aggregates are initialized. 

#### Preparing our Aggregate Module

Currently, to instantiate our ShoppingCart, we must provide a `uuid`:

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

What about when we need to _rebuild_ an aggregate? We cannot instantiate an empty Aggregate without enqueuing a "start" event - in our case, a `CartOpened`. There are a few options.

We could move the responsibilities of _building_ a new ShoppingCart to a `build` method, that will instantiate the Aggragate and `apply` the correct event but there are some drawbacks. We now have _two_ methods for instantiating objects and it can be confusing which one to use, especially as more Engineers join the project.

We could move the responsibility of instantiating a new `ShoppingCart` aggregate and `CartOpened` event to the repository, where a new Aggregate is instatiated and the `CartOpened` starting event is applied. This too, has some drawbacks. For one, the _event_ which belongs to the domain model is now part of the Repository! The model has very little control over when these events become applied. No bueno!

I'm sure there are a few other clever ways we can do this in ruby but there is one pragmatic way I've come to enjoy: nullified arguments!

When instantiating a new Aggregate, we can allow passing in a `uuid` as `nil`. By doing so this allows the aggregate to choose to enqueue a new starting event or not. The aggregate retains control of when events are published and keeps a single method for instantiating aggregates.

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
- Ensure the latest version is set
- If no events can be found _or_ for some reason the `uuid` is _`nil`_, return `nil`

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

Our new `fetch` starts be instantiating a blank `ShoppingCart` by passing in `nil` as the `uuid`. This means it has not enqueued a `CartOpened` event. It then events are queried from DynamoDB using a the `key_condition_expression`.

In order to ensure we are querying for all available records, we must paginate over the evaluation set. 

If it _cannot_ find any events, it returns `nil` Otherwise, it loops over each record, first _initializing_ an event and then _applying_ it against the aggregate.

At the end, if the `uuid` is not `nil`, you can return the rehdrated `ShoppingCart`. Otherwise, `nil`. 

#### When would `uuid` be nil?

If our query returns a collection of events and our starting event _always_ provides a `uuid`, when would it be `nil`?

One of the core aspects of event sourcing is that events are **never** deleted nor altered. The event store is append only and the events themselves are immutable! This begs the question, how are Aggregates then "deleted"?

By another event of course! In eventually consistent systems, an event which signifies the end of an object is called a [Tombstone](https://en.wikipedia.org/wiki/Tombstone_(data_store)). The motiviation section in the Wikipedia entry describes this as (emphasis my own),

> If information is deleted in an eventually-consistent distributed data store, the "eventual" part of the eventual consistency causes the information to ooze through the node structure, **where some nodes may be unavailable at time of deletion**. But a feature of eventual consistency causes a problem in case of deletion, as a node that was unavailable at that time will try to "update" the other nodes that no longer have the deleted entry, assuming that they have missed an insert of information. Therefore, **instead of deleting the information, the distributed data store creates a (usually temporary) tombstone record**, which is not returned in response to requests.

When our aggregate should be deleted, a new event is enqueued which sets the `uuid` to `nil` effectivly deleting it. Eventually, downstream consumers will receive this event and decide what a tombstone means for their domain.

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

Our repository is looking good but it's breaking a few SOLID rules. If we carefully read through its code, two things stand out:
- There are a wide array of responsibilities in a single class.
- Aside from the events, there is hardly anything about this implementation that seems ShoppingCart specific. 

We can make this far better.

### Refactoring

We'll refactor our `ShoppingCartRepo` to abstract persistence behaviours into a base class. Our aim is to acheive two objectives:
- All aggregate repositories may inherit from the same base class and behave the same way.
- A separation of concerns is desirable to produce more easily readable code.

Martin Fowler's _[Refactoring](https://martinfowler.com/books/refactoring.html)_ describes a fantastic set of approaches to refactoring. We'll apply a few here.

#### EventBuilder Class

Our repository does not need to understand how events are built. It may delegate this to a second class. Using the _[Extract Class](https://refactoring.com/catalog/extractClass.html)_ refactoring, we'll extract this behaviour to it's own class and inject it as a dependency.

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

Injecting new class as a dependency and replacing the existing build implementation with a call to the `event_builder` object.

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

First, we'll use _[Extract Function](https://refactoring.com/catalog/extractFunction.html)_ refactoring to move data persistence from `store` into it's own method.

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

Next, we'll use _Extract Class_ refactoring once again to move data access into it's own class. Luckily for us, _querying_ events is already isolated into it's own method.

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

Now, our `ShoppingCartRepo` is looking much simpler.

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

Future aggregate repos mill benefit from an existing class which implements aggregate rehydration and storing behaviours.

First, we'll define our new parent class and inherit it from `ShoppingCartRepo` class.

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

There is one last thing alteration that is necessary to make. `DynamoDBRepo` class still references the `ShoppingCart` aggregate.

We can fix this with a little bit of meta-programming by making the `ShoppingCart` class tell it's parent what sort of aggregate it needs.

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

Now we may configure our repository by specificying it should persist and build `ShoppingCart` aggregates.

```ruby
class ShoppingCartRepo < DynamoDBRepo
  aggregate ShoppingCart
end
```

Personally, I believe the same behaviour should be used for the `EventBuilder` class as well.

By using the _[Pull Down Field](https://refactoring.com/catalog/pushDownField.html)_ refactoring, we can acheive the same result. I'll omit the details from here, as we'll conclude with a breif overview momentarily.

```ruby
class ShoppingCartRepo < DynamoDBRepo
  aggregate ShoppingCart
  event_builder Events::Builder
end
```

### Refactoring Conclusion

This style of refactoring invovles making smaller adjustments that marginally improves a problem. It favors small consistent wins over large - and possibly dangerous - restructorings.

Quite a few changes were presented with omitted code blocks. For a full capture of the `ShoppingCartRepo`, `DynamoDBRepo`, and `EsDynamoTableClient` classes, you may view them over this [GitHub Gist](https://gist.github.com/APiercey/2960739a7ec3bd2bfdfdc4cc557d42d6).

## Test Run

Let's take our new repository for a spin.

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

Taking a peak into our DynamoDb table, we see the record there, with the set of changes as events.

![Event Store](/images/aws-eventsourcing/inspect-dynamo-db.png)

We can fetch the same shopping cart and inspect it's state.
```ruby
rehydrated_shopping_cart = shopping_cart_repo.fetch("test-uuid")

rehydrated_shopping_cart.inspect
```

`inspect`ing the object should show us a complete `ShoppingCart` with a `uuid` and an `item`.

![Event Store](/images/aws-eventsourcing/inspect-shopping-cart.png)

## Conclusion

We've brought our Aggregates full circle and can now create them and rehdrate them for future use. We've done so be leveraging DynamoDB.

Additionally, we saw how we can refactoring complex classes to become gradually more simple.

Next, we will take the first step into building event handlers for these events using _Change Data Capture_. We'll accomplish this using DynamoDB Streams, Lambda, and Kinesis!
