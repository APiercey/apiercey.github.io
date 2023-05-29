---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Three: Aggregate Persistence"
date: 2023-04-28
description: How complex objects are persisted and how we can tame object complexity by refactoring.
image: images/event-sourcing.jpg
showTOC: true
draft: false
list: "never"
useComments: true
utterenceIssueNumber: 1

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
  - terraform
  - event store

---

_This is the third part in an on-going blog series about [building an event sourcing system in Ruby using AWS Serverless technologies](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/introduction)._

The persistence of values and complex objects is essential to modern applications. Applications that take tremendous care of how their objects actually pass in-and-out of memory tend to perform far better than those that don't - especially in the face of changing and growing requirements.

This article covers how to implement aggregate persistence using the Repository pattern and DynamoDB. We will start by designing our event store and building the first component - the events table.

## Designing an Event Store

Event stores are database in an event sourced system. It allows querying and persisting events and is the single source of truth for system data.

While an event store may be implemented with many different technologies it should meet 4 key criteria:
- The ability to persist ordered events.
- The ability to fetch a range of events (or all events).
- The ability to push events to downstream listeners.
- The ability to prevent conflicting changes at the same time.

Our event store will be implemented using DynamoDB, Lambda, and Kinesis. Let's review each criteria in turn.

### The Ability to Persist Ordered Events

Event ordering is paramount for event sourced aggregates. Aggregate events out of order can have diasterous effects. 

For example, in accounting systems, accounts that are overdrawn (have negative funds) are usually subject to fixed fees regardless of the time span they are overdrawn.

Let's say Bob deposits 100 dollars on Monday and withdraws 50 dollars on Tuesday. This means there are two events stored in the event store:
- FundsWithdrawn: $100 on Monday
- FundsDeposited: $50 on Tuesday

If the downstream application responsible for applying overdrawn fees received the FundsDeposited event first before the FundsWithdrawn, poor Bob would loss money (and the customer support member receiving a not-so-fun phone call)!

### The Ability to Fetch a Range of Events

A flexible event store allows fetching events from any time range. Traditionally, when using an event store to rehydrate an aggregate, all events are fetched to build up the state. Expressed as _`[first..last]`_

However, some aggregates may be more popular than others and outside its normal lifecycle. In such cases, these aggregates may have hundreds of events and rehydration takes substantially longer than normal and consumes far greater amounts of memory.

Through a process called _snapshoting_ an aggregate's complete state may be recorded as an event. From there, only a range starting from the _last_ snapshot till the latest event is necessary. Expressed as _`[n..last]`_

Finally, in some cases a historical range needs to be examined. Expressed as _`[a..b]`_.

There are two common cases:
- An audit or inspection question is posed, "When did _x_ happen to aggregate _y_?".
- A report must be composed. A range of events can be replayed, building report information.

Snapshoting is outside the scope of this series, however, as it comes with its own set of challenges. It's imperative to be aware of the pattern if you are experiencing this problem.

### The Ability to Push Events to Downstream Listeners

[In the first article](../system-design/#what-problem-does-it-solve), one of the primary reasons for introducing event sourcing is to provide stronger guarantees when informing interested parties about data changes. Therefore, this requirement falls under the scope of responsibility of the event store.

An event store which does not provide this functionality may still be used but the burden falls on either the engineer utilizing the event store to provide a mechanism of informing interested parties or said parties must periodically query the event store looking for new events.

### The Ability to Prevent Conflicting Changes at the Same Time

Consider two requests entering a system at the same time, requesting to change a person's name.

1. Request One opens a transaction.
2. Request Two opens a transaction.
3. Request One changes the person's name to "Alex"
4. Request Two changes the person's name to "Alexander"
5. Request Two commits the transaction.
6. Request One commits the transaction.

Despite starting last, request two beats request one to the punch. This software would leave users confused about why their name isn't what they expected.

In a more series scenario, such as moving money between accounts, the risk can be much higher. A well-designed event store prevents such scenarios from transpiring.

The most accepted approach is a strategy known as _Optimistic Locking_. We'll discuss this in detail in this article.

### Design Overview

Our event store will utilize four AWS technologies to meet the key criteria:

- DynamoDB to store aggregate events and provide optimistic locking. It will act as hot storage.
- Kinesis Streams for pushing events to our to interested parties.
- S3 Bucket to store aggregates events for long term storage. It will act as cold storage.
- Two Lambdas:
  - The first to capture newly added events added to our DynamoDB table and push them to our Kinesis Stream. This will act as an event publisher.
  - The second subscribes to the Kinesis stream and records events to the cold storage (the S3 Bucket).

![Event Store Design](/images/aws-eventsourcing/eventstore-design.jpg)

#### Hot vs Cold Storage

The hot event storage provides immediate access to events and allows the insertion of new events under optimistic locking. Here, guarantees are made about the data being inserted into the store. Any events added here gain immediate consistency.

Reading these events must be fast and in tune with our store's the non-functional _Write_ requirements.

On the opposite side, cold event storage provides infrequent access more aligned with out store's non-function _Read_ requirements.

Large batches of events can be read without impacting write-side performance and subjecting ourselves to large overhead costs.

For example, with tools such as [Athena](https://aws.amazon.com/athena/), we can query our events using SQL to build reports or derive business insights.

## DynamoDB Events Table

DynamoDB is a serverless Document DB from AWS that scales according to demand. A DynamoDB table does not belong to an overarching entity, unlike traditional databases.

To implement a table, it requires only a few things:
- A table name.
- A primary key, called a hash key. Must be unique.
- And optionally, a range key, which acts as a second lookup key. Must be unique only for its primary key.

The primary key will act as the lookup key for the value. It's possible to provide additional lookup keys, called Global or Local Secondaries, but they won't be necessary for our implementation.

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

The hash key (primary key) will be named `AggregateUuid` and store our aggregate's identifier.

We'll also include a range key named `Version`. Versions facilitate Optimistic Locking, so we'll dive deeper later. Unfortunately, due to a flaw in DynamoDB we must provide range keys upfront if we wish to use them.

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

Now our module is ready to be used. Let's define the module in our infrastructure directory.

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

Logging into AWS and looking at DynamoDB, we can see our table. One really great feature of DynamoDB is that you can inspect tables and their items from the console which makes debugging a breeze.

![Events Table](/images/aws-eventsourcing/dynamodb-scd.png)

Additional event store components will be added in future articles.

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


When persisting changes, each change will be persisted as a unique record in our DynamoDB table. Record uniqueness is guaranteed by two attributes:
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

One critical detail to remember, `Version` is a _range_ field. It is only unique for its given _range_ (`AggregateUuid`).

#### Clearing Changes

Lastly, our `store` method needs to clear persisted events. We can achieve this by implementing a method in the `Aggregate` module.

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
- Ensure the latest version is set
- If no events can be found _or_ the `uuid` is _`nil`_, return `nil`

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

In order to ensure we are querying all available records, we must paginate over the evaluation set. 

If it _cannot_ find any events, it returns `nil` Otherwise, it loops over each record, first _initializing_ an event and then _applying_ it against the aggregate.

At the end, if the `uuid` is not `nil`, you can return the rehdrated `ShoppingCart`. Otherwise, `nil`. 

#### When would `uuid` be nil?

If our query returns a collection of events and our starting event _always_ provides a `uuid`, when would it be `nil`?

One of the core aspects of event sourcing is that events are **never** deleted nor altered. The event store is append-only and the events themselves are immutable! This begs the question, how are aggregates "deleted"?

By another event of course! In eventually consistent systems, an event that signifies the end of an object is called a [Tombstone](https://en.wikipedia.org/wiki/Tombstone_(data_store)). The motivation section in the Wikipedia entry describes this as (emphasis mine),

> If information is deleted in an eventually-consistent distributed data store, the "eventual" part of the eventual consistency causes the information to ooze through the node structure, **where some nodes may be unavailable at time of deletion**. But a feature of eventual consistency causes a problem in case of deletion, as a node that was unavailable at that time will try to "update" the other nodes that no longer have the deleted entry, assuming that they have missed an insert of information. Therefore, **instead of deleting the information, the distributed data store creates a (usually temporary) tombstone record**, which is not returned in response to requests.

When our aggregate should be deleted, another event is enqueued which sets the `uuid` to `nil` effectively deleting it. Eventually, downstream consumers will receive this event and decide what a tombstone means for their domain.

Consider the diagram below.

In this application, there exists an Ordering System which produces events into a stream. In this particular frame in time, a series of events have occurred which signal the creation of an object through a starting event and the deletion of an object through a tombstone event.

The Ordering System is immediately consistent, so it knows that data has been deleted. Downstream System A has already processed all events that have occurred in the event stream and knows that data has been deleted as well.

However at the same time, Downstream System B is about to discover that data has been deleted from the Ordering System. While Downstream System C hasn't even known the data existed in the first place.

![Tombstone Events](/images/aws-eventsourcing/tombstone-events.jpg)

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
- Aside from the events, there is hardly anything about this implementation that seems ShoppingCart specific. 

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

We've brought our aggregates full circle and can now create and rehydrate them for future use. We've done this by leveraging DynamoDB.

Additionally, we saw how we could refactor complex classes to become gradually more simple.

The full code for part three of our event sourcing application can be found here: https://github.com/APiercey/aws-serverless-event-sourcing/tree/part-three-aggregate-persistence

Next, we will take the first step into building event handlers for these events using _Change Data Capture_. We'll accomplish this using DynamoDB Streams, Lambda, and Kinesis!
