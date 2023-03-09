---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Three: Aggregate Persistence"
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: true
draft: false
useComments: true
disqusIdentifier: "event-sourcing-with-ruby-part-3-aggregate-persistence"
---

# Aggregate Persistence
- Basic DynamoDB table
  - None of the Event CDC stuff
  - Basic UUID
  - Include some additional Cloudwatch stuff
- Ruby implementation of Repo
 - only has two methods
 - Designed to handle the _write_ nature of business requirements and not the read
 - Fetch method implementation
 - Store method implementation
- Implement ShoppingCartRepo
- At this time of writing, AWS only supports Ruby 2.7 natively. So we wont use fancy new 3.x features

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

The `fetch` method has one responsibility: Fetch events using a `uuid` and apply them against an aggregate.
- Persisting new events (changes) that are stored on the aggregate.
- Clearing persisted events and returning a clean aggregate, ready for further interactions. 
``````

## Conclusion

TODO

# DynamoDB and CDC
- DynamoDB Streams and what are they
- Implement OpenCart, GetCart, and AddItem Lambdas
- Demonstrate Rebhydrating aggregates
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
