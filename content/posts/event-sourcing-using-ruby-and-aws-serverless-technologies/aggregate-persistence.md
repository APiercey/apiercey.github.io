---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Three: Aggregate Persistence"
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: true
draft: true
useComments: true
disqusIdentifier: "event-sourcing-with-ruby-part-3-aggregate-persistence"
---

# Aggregate Persistence
- [x] Basic DynamoDB table
  - [x] None of the Event CDC stuff
  - [x] Basic UUID
  - [ ] Include some additional Cloudwatch stuff
- Ruby implementation of Repo
 - [x] only has two methods
 - [ ] Designed to handle the _write_ nature of business requirements and not the read
 - [x] Fetch method implementation
 - [x] Store method implementation
- [x] Implement ShoppingCartRepo
- [ ] At this time of writing, AWS only supports Ruby 2.7 natively. So we wont use fancy new 3.x features
- [x] Demonstrate Rebhydrating aggregates

-----

This is part 3 of an ongoing series where we build an EventSourced system in Ruby using AWS Serverless Technologies.

We're going to implement aggregate persistence by using the Repository pattern and DynamoDB, so let's jump into it!

## DynamoDB Tables

DynamoDB is serverless Document DB by AWS that scales automatically to meet your demand. However, there is a difference between DynamoDB and other tranditional databases.

There are no databases - only tables! 

Yes, as odd as that may seem, we don't collect tables under a single database but rather a Table is our top-level artifact.  

TODO: Why does AWS do it like this?

To implement a table, very few things are necessary:
- A tablename
- A primary key

The primary key will act as the the lookup key for the value. It's possible to provide additional lookup keys, called Global Secondaries, but they won't be necessary for our implementation.

## ShoppingCart Table in Terraform

The first piece of infrastrcture we will build will be our EventSourced table for ShoppingCarts.

When implementing Infrastrcutre as Code with Terraform, we must define each piece of our infrastrcture as a distinct resource. After a while, common patterns emerge of what we typically want to include when building infrastrcture.

A great example that we will see later, is when we build our lambdas we will also want a Cloudwatch Log Group to log to! These two pieces go well together and it would be tedious to implement them both _every_ time we needed them.

Luckily for us, Terraform allows us to build custom modules where we can build a group of related infrastrcture together aptly called _modules_.

We will start by defining a module for our EventSourced table where related infrastrctures will be placed.

### Defining the Module

A Terraform module is simply a directory:

```bash
mkdir event_source_table

touch event_source_table/dynamodb.tf
touch event_source_table/variables.tf
```

Our tables primary key will be called `Uuid` and will store our aggregates' identifier. The implementation looks like so:

```terraform
# event_source_table/dynamodb.tf

resource "aws_dynamodb_table" "es_table" {
  name     = var.table_name # Variables come next
  hash_key = "Uuid"

  # Describe `Uuid` as a String
  attribute {
    name = "Uuid"
    type = "S"
  }

  # For testing, low read and write capacity is just fine. In production systems, you may require different capacities
  read_capacity = 1
  write_capacity = 1
}
```

Our table will require a name, which we can supply as a variable:

```terraform
# event_source_table/variables.tf

variable "table_name" {
  type = string  
}
```

Now our module is ready to be used, let's source it and build our infrastrcture:

```terraform
# main.tf

# Use AWS as a terraform provider
provider "aws" {
  version = "~> 4.57"
  region  = "us-east-1" # feel free to choose a new region
}

module "shopping-carts-table" {
  source = "./event_source_table"

  table_name = "ShoppingCarts"
}
```

Our `main.tf` sources our custom module to create a group of resources under the named `shopping-carts-table`.

We can apply terraform code by running
```bash
$ terraform apply
```

Logging into AWS and looking at DynamoDB, we can see our table. One really great feature of DynamoDB is you can inspect tables and their items from the console which makes debugging a charm.

TODO: Insert screenshot.


## ShoppingCart Repository

With our table ready to be used, we can turn our attention towards the code that will interface with it: The `ShoppingCartRepository`.

### About the Repository Pattern

The repository pattern is a data (no abstraction... what that other word?!) pattern for _querying_ and _persisting_ objects. It's responsibility is to ensure it provides _whole_ objects when fetching them and persisting _all_ changes when saving them.

Often, Repository Pattern is compared against the ActiveRecord pattern. The two key differences are:
- With the ActiveRecord pattern, the persistence methods are implemented on the Entites themselves.
- With the Repository pattern, entire objects and their "dependencies" _must_ be fetched and built. Where as with ActiveRecord, related objects can be queried for after the initial data access.

So how is this pattern implemented? Well...

The literature around the repository pattern can be a bit eclectic and hard to understand at times. A lot of it is opinion based and handed down, from one generation of engineering teams to another. So let's get on the same page of what _we_ want to build.

TODO: Get a link

I quite enjoy the way Vaugn Vernon summaries Repositores in his book, [_Implementing Domain Driven Design_](_Implementing Domain Driven Design_) (A.K.A 'The Red Book'), which I'll paraphrase:

> There are two kinds of repositories. The first, acts as a collection and provides an interface for querying either single Entities or entire collections of entities. Changed entities are persisted by passing them to a `save` method. The second kind, provides only two methods: `fetch` and `store`, which fetch and persist changed Entities respectfully.

A nice way to look at this is, there are two types of Repository patterns:
- One which is _really_ great at meeting complex querying needs. This is highly suited for the Q in CQRS.
- One which is _really_ great at building and saving single complex object. This is highly suitd for the C in CQRS.

For our EventSourcing application, we will build the later.

### Repository Outline

Our Repository will have only two methods: `fetch` and `store`, where fetch takes a `uuid` and store takes an entire Aggregate.

Additionally, our Repository will require access to DynamoDB. This will be injected as a dependency.

```ruby
class ShoppingCartRepository
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

The `store` method has two responsibilities:
- Persisting new events (changes) that are stored on the aggregate.
- Clearing persisted events and returning a clean aggregate, ready for further interactions. 

```ruby
class ShoppingCartRepository
  # ...
  def store(shopping_cart)
    update_aggregate_record(shopping_cart)
    shopping_cart.clear_changes

    shopping_cart
  end
  
  def update_aggregate_record(shopping_cart)
    new_events = shopping_cart.changes.map { |event| { Name: event.class::NAME, Data: event.to_h } }

    @dynamodb_client.update_item({
      table_name: "ShoppingCart",
      key: {
        Uuid: shopping_cart.uuid
      },
      update_expression: "SET #el = list_append(if_not_exists(#el, :empty_list), :new_events)",
      expression_attribute_names: {
        "#el" => "Events",
      },
      expression_attribute_values: {
        ":empty_list" => [],
        ":new_events" => new_events
      },
    })
  end
end
```

Lot's to unpack here, so let's break it down. First, the `update_aggregate_record` method.

First, we transform new events into a structure suited for persistence. DynamoDB is a document store, so it can handle Hash just fine.

Our persisted events will be stored in a attribute named `Events` as an array of hashes with the following keys: `Name`, which is the name of our event, and `Data`, which is our event data.

In order to accomplish this, our events need to implent a `to_h` method. Let's do that now:

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

Great, so the rest of the method is DynamoDB syntax for _updating or inserting_ a record. We provide enough logic of what should happen if the record doesn't exist.

In the case that a record does not exist, it's going to insert a new one with the `Uuid` as the `shopping_cart.uuid` and the `Events` will be an merge of two lists: an empty list (`[]`) and a list of new events. DynamoDB calls this `list_append`.

In the case that a record does exist, `Events` will be updated with a merge of two lists: the old `Events` list and a list of new events.

Lastly, we need to clear the persisted events. We can achieve this by implementing a method to do so in the `Aggregate` module.

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

#### Test Run

```ruby
require 'aws-sdk-dynamodb'

# DynamoDB Client
dynamo_db_client = Aws::DynamoDB::Client.new

# ShoppingCartRepo, dependecies injected
shopping_cart_repo = ShoppingCartRepo.new(dynamo_db_client)
  
shopping_cart = ShoppingCart.new("test-uuid")

shopping_cart.add_item("apiercey.github.io subscription")

# There should now be two events in @changes

puts shopping_cart.inspect

shopping_cart_repo.store(shopping_cart)
```

Taking a peak into our DynamoDb table, we see the record there, with the set of changes as events.

TODO: Insert screenshot

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

But what about when we need to _rebuild_ an aggregate? We cannot instantiate an empty Aggregate without enqueuing a "start" event - in our case, a `CartOpened`. There are a few options

We could move the responsibilities of _building_ a new ShoppingCart to a `build` method, that will instantiate the Aggragate and `apply` the correct event but there are some drawbacks. We now have _two_ methods for instantiating objects, and it can be confusing which one to use, especially as more Engineers join the project.

We could move the responsibility of instantiating a new ShoppingCart to the repository, where a new Aggregate is instatiated and the correct starting event is applied. This too, has some drawbacks. For one, the _event_ which belongs to the domain model is now part of the Repository! The model has very little control over when these events become applied and this is no bueno!

I'm sure there are a few other clever ways we can do this in ruby but there is one pragmatic way I've come to enjoy: nullified arguments!

When instantiating a new Aggregate, we can allow passing in a `uuid` as `nil`, and allow the event to choose to enqueue a new starting event or not. This will allow the aggregate to retain control of when events are published and keeps a single method for instantiating aggregates.

Our new ShoppingCart looks like so:

```ruby
class ShoppingCart
  include Aggregate

  attr_reader :items

  def initialize(uuid = nil) # uuid is allowed to be nil
    @items = []

    enqueue(CartOpened.new(uuid)) unless uuid.nil? # if it's new, it's a black object
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

The `fetch` method has two responsibilities:
- Fetch previous events using a `uuid` and apply them against an aggregate.
- If no events can be applied _or_ for some reason the `uuid` is _`nil`_, return `nil`

```ruby
class ShoppingCartRepo
  def initialize(dynamodb_client, event_builder)
    @dynamodb_client = client
    @event_builder = event_builder
  end
  
  def fetch(uuid)
    agg = ShoppingCart.new # A blank aggregate

    record = fetch_aggregate_record(uuid)

    return nil if record.nil?

    record
      .fetch("Events", [])
      .map { |event| build_event(event) }
      .reject(&:nil?)
      .each { |event| agg.apply(event) }

    if agg.uuid.nil?
      nil
    else
      agg
    end
  end

  private

  def fetch_aggregate_record(uuid)
    @dynamodb_client.get_item({
      table_name: "ShoppingCart",
      key: { Uuid: uuid }
    }).item
  end
  
  def build_event(raw_event)
    @event_builder.build(raw_event.fetch('Name'), raw_event.fetch('Data'))
  end
  
  # ...
end
```

Our new `fetch` starts be instantiating a black ShoppingCart (it has not enqueued a `CartOpened` event). It then fetches a record from DynamoDB with the `uuid` as the Primary Key. If it _cannot_ find a record, it simply returns `nil`.

Otherwise, it loops over each event stored under `Events`, first _building_ themm then _applying_ them.

At the end, if the `uuid` is not `nil`, you can return the rehdrated `ShoppingCart`. Otherwise, `nil`. However, we've introduced a new clas to help build events. Here it is:

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

#### When would `uuid` be nil?

So what gives? If we can find the record and the starting event _always_ provides a `uuid`, when would it be `nil`?

One of the core aspects of EventSourcing is that events are **never** deleted nor altered. They are immutable! This begs the question, how are Aggregates then "deleted"?

By another event of course! In eventually consistent systems, an event which signifies the end of an object is called a [Tombstone](https://en.wikipedia.org/wiki/Tombstone_(data_store)). The motiviation section in the Wikipedia entry describes this as (emphasis my own),

> If information is deleted in an eventually-consistent distributed data store, the "eventual" part of the eventual consistency causes the information to ooze through the node structure, **where some nodes may be unavailable at time of deletion**. But a feature of eventual consistency causes a problem in case of deletion, as a node that was unavailable at that time will try to "update" the other nodes that no longer have the deleted entry, assuming that they have missed an insert of information. Therefore, **instead of deleting the information, the distributed data store creates a (usually temporary) tombstone record**, which is not returned in response to requests.

When our aggregate should be deleted, a new event is enqueued which sets the `uuid` to `nil` effectivly deleting it. Eventually, downstream consumers will receive this event and decide what a tombstone means for their domain.

In our ShoppingCart, such an example could be:

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

#### Test Run

```ruby
require 'aws-sdk-dynamodb'

# DynamoDB Client
dynamo_db_client = Aws::DynamoDB::Client.new
event_builder = EventBuilder.new

# ShoppingCartRepo, dependecies injected
shopping_cart_repo = ShoppingCartRepo.new(dynamo_db_client)
  
shopping_cart = ShoppingCart.new("test-uuid")

shopping_cart.add_item("apiercey.github.io subscription")

shopping_cart_repo.store(shopping_cart)

rehydrated_shopping_cart = shopping_cart_repo.fetch("test-uuid")

puts rehydrated_shopping_cart.inspect
```

We should expect to see a complete `ShoppingCart` with a `uuid` and an `item`.

## Small Cleanup

Our repo is looking good but it could be better, it could be _great_, in fact! If we carefully read through our Repo, there is hardly anything that is specific about "shopping cards" really. Events are built using a separate class and even the Table is a hard coded string. All of these things can be supplied at run time, allowing us to refactor this repo to allow it to become a repo for _all_ aggregates. 

We can accomplish this by doing two things:
- Moving these values to the initialize method
- Moving everything to parent class and inherit from it.

```ruby
class EsRepo
  def initialize(dynamodb_client, event_builder, table_name, aggregate_class)
    @dynamodb_client = dynamodb_client
    @event_builder = event_builder
    @table_name = table_name
    @aggregate_class = aggregate_class
  end

  def fetch(uuid)
    agg = @aggregate_class.new

    record = fetch_aggregate_record(uuid)

    return nil if record.nil?

    record
      .fetch("Events", [])
      .map { |event| build_event(event) }
      .reject(&:nil?)
      .each { |event| agg.apply(event) }

    if agg.uuid.nil?
      nil
    else
      agg
    end
  end

  def store(agg)
    update_aggregate_record(agg)
    agg.clear_changes

    agg
  end

  private

  def fetch_aggregate_record(uuid)
    @dynamodb_client.get_item({
      table_name: @table_name,
      key: { Uuid: uuid }
    }).item
  end

  def update_aggregate_record(agg)
    new_events = agg.changes.map { |event| { Name: event.class::NAME, Data: event.to_h } }

    @dynamodb_client.update_item({
      table_name: @table_name,
      key: {
        Uuid: agg.uuid
      },
      update_expression: "SET #el = list_append(if_not_exists(#el, :empty_list), :new_events)",
      expression_attribute_names: {
        "#el" => "Events",
      },
      expression_attribute_values: {
        ":empty_list" => [],
        ":new_events" => new_events
      },
    })
  end

  def build_event(raw_event)
    @event_builder.build(raw_event.fetch('Name'), raw_event.fetch('Data'))
  end
end
```

Our new `ShoppingCart`:

```ruby
class ShoppingCartRepo < EsRepo ; end
```

This isn't the only way to accomplish this but I think it's pragmatic enough :). In this case, even the `ShoppingCartRepo` class isn't necessary from the perspective of initializing a repo but I think the Repo has a fundamental place in our code base and should still be represented as a first-class object.

## Conclusion

We've brought our Aggregates full circle and can now create them and rehdrate them for future use. We've done so be leveraging DynamoDB.

Next, we will take the first step into building event handlers for these events using _Change Data Capture_. We'll accomplish this using DynamoDB Streams and Lambda!

TODO

# DynamoDB and CDC
- DynamoDB Streams and what are they
- Implement OpenCart, GetCart, and AddItem Lambdas
- Introduce Lambda to capture changes
  - Pluck new events from Aggregate changes
  - Simple event logging for now

# Kinesis and Downstream Event Handlers
- What is Kinesis
- Lambda that captures changes should publish to Kinesis
  - Map DynamoDB to JSON
  - PutRecord/s
- EventHandler to handle 
- Publish to S3 for long term storage
- Share idea on introducing a lambda to replay events
- Improving Kinesis https://dashbird.io/blog/lambda-kinesis-trigger/
