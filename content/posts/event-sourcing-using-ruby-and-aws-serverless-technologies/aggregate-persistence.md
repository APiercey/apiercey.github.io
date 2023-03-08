---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Two: Aggregate Design in Ruby"
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: true
draft: false
useComments: true
disqusIdentifier: "event-sourcing-with-ruby-part-2-ruby-and-aggregates"
---

# Ruby and Aggregates
- At this time of writing, AWS only supports Ruby 2.7 natively. So we wont use fancy new 3.x features
- Ruby implementation of an Aggregate
- Implement ShoppingCart

- TODO: Add Aggregate Design

-----

## Aggregate Crash Course

Aggregates are group of objects that enforce business constraints with **one** of the objects acting as the root object. The root object acts as the spokesobject for the others and nothing can access the internal objects without going through the root object first. In DDD nomenclature, these objects are composed of Entities and Value objects.

A quick example. If you have an account and bookings made against the account, the relationship could look like this:

TODO: Insert image of account and transactions.

If the business rules make it imperative that you **absolutely, under any circumstances, cannot have a booking unassociated to an account**, then the only way to access a booking would be to go through it's account!

```ruby
account = AccountRepository.fetch(account_identifier)
=> #<Account @uuid="..." @bookings=[#<Booking ...>, ...]>

account.bookings
=> [#<Booking ...>, ...]
```

The account is the gatekeeper for all business logic. If we need to execute logic against a booking, we must go through the account:

```
account.revert_booking(booking_uuid)
=> #<Account @uuid="..." @bookings=[#<Booking ...>, ...]>
```

To help enforce this business constraint, we must _neglect_ to create a Repository for fetching bookings.

If you're interested in aggregate design, I highly recommend the following articles:

## Aggregates in Ruby

Like other architectures coming from DDD circles, EventSourcing separates the idea of persistence from the model itself.

There is quite a signifacnt benefit to this: Our model objects become much simpler and easier to reason about.

An aggregate in event sourcing works like this:

You have an object (your aggregate) and you want to execute a method to carry out some business logic. The result of doing so, is _publishing_ an event. Whenever an event is published, it will immediatly be _applied_ to the object and the object state will change.

This means that:
- Object state isn't modified during action execution of business logic
- Method for executing business logic are responsibile for _enforcing_ the rules (E.g. Account balance cannot go below zero!)
- For every action that modifies an aggregate, there is an event.
- New published events to an aggregate are stored in memory, waiting to be persisted.


TODO: Insert image of aggregtate publishing an event and being applied

Our aggregates will publish many events which desribes it's lifecycle. In the example of an account, it's wouldn't be untypical to events named:
- AccountOpened
- FundsWithdrawn
- FundsDeposited
- AccountInOverdraft
- AccountNoLongerInOverdraft
- AccountClosed

These names describe what is happening _in the domain_ the account lives in.

### Defining a ShoppingCart

Our shopping cart will be simple: You can open a shopping cart and you can add items to it. We'll start with a tiny class definition.

```ruby
class ShoppingCart
  attr_reader :items
end
```

Now, we're ready to explore publishing our first event!

To create an aggregate, we need two simple things:
- An identifier, ussually a [UUID](UUID)
- An event, which signifies the _starting_ event of that aggregate. In the CRUD world, this is the _creation event_.

### Aggregate Design: Events

Events themselves are very simple. They are a static structure that describes a _fact_ that has happened and can be implemented as a PORO.

_They are immutable._

_They are desribed in the past tense._

_They are not commands/actions._

Let's define our first.

```ruby
class CartOpened
  attr_reader :shopping_cart_uuid

  def initialize(shopping_cart_uuid)
    @shopping_cart_uuid = shopping_cart_uuid
  end
end
```

Simple and neat.

Let's implement just enough of our first aggregate to publish this event.

Once a `CartOpened` object has been instantiated, it cannot be modified (Okay - yeah yeah! Clever Rubysists will figure it out how it's possible! But let's be pragmatic :])

### Aggregate Design: Publishing Events

```ruby
module Aggregate
  def self.included(base)
    base.class_eval do
      attr_reader :uuid
    end
  end
  
  def changes
    @changes ||= []
  end

  private
  
  def enqueue(event)
    changes.append(event)

    self
  end
end
```

Our `Aggregate` module will host the abstract behaviour of all aggregates. It's responsible for managing the events as `changes` and aggregate `uuid`.

Whenever an event is enqueued to be published using the `enqueue` method, it will store that event as a `change`. We will see how these changes can be applied and published later.

```ruby
class ShoppingCart
  include Aggregate

  attr_reader :items

  def initialize(uuid)
    @items = []

    enqueue(CartOpened.new(uuid))
  end
end
```

When our `ShoppingCart` is instantiated, it will build a new `CartOpened` event and `enqueue` this change to be published.

```ruby
ShoppingCart.new("test-uuid")
=> #<ShoppingCart:0x0000000155b7cd60 @items=[], @changes=[#<CartOpened:0x0000000155b7cd10 @shopping_cart_uuid="test-uuid">]>
```


We can see the changes have been enqueued, waiting to be used, with no `uuid` insight. We are now ready to move on with a great foundation.

### Aggregate Design: Applying Events

Now that our ShoppingCart aggregate understands events and can enqueue them, our state still hasn't changed yet. In the step above, it has no `uuid`! Let's expand our `Aggregate` module to start applying events.

```ruby
module Aggregate
  def self.included(base)
    base.class_eval do
      attr_reader :uuid
      
      def self.on(event_class, &block)
        define_method "apply_#{event_class::NAME}", &block
      end
    end
  end
  
  def changes
    @changes ||= []
  end
  
  def apply(event)
    self.send("apply_#{event.class::NAME}", event)

    self
  end

  private
  
  def enqueue(event)
    apply(event)
    changes.append(event)

    self
  end
end
```

And now define how these events should be applied in our ShoppingCart

```ruby
class ShoppingCart
  include Aggregate

  attr_reader :items

  def initialize(uuid = nil)
    @items = []

    enqueue(CartOpened.new(uuid)) unless uuid.nil?
  end

  on CartOpened do |event|
    @uuid = event.shopping_cart_uuid
  end
end
```

Now, there is some meta-programming happening here, so let's take some time to explore what is happening under the hood.

```ruby
module Aggregate
  # ...
  def self.included(base) # This will execute whenever the module is included
    base.class_eval do
      attr_reader :uuid
      
      def self.on(event_class, &block) # This will become a class method for our aggregate
        define_method "apply_#{event_class::NAME}", &block
      end
    end
  end
  # ...
end
```

The `self.on` class method accepts two arguements, an event class object and a ruby block. It's responsible for defining a new method _at run time_ where the body of the new method is the block that is passed in.

The `define_method` is the wizard casting this magic. It accepts two arguments: the name of the method and a block.

```ruby
module Aggregate
  # ...
  def apply(event)
    self.send("apply_#{event.class::NAME}", event)

    self
  end

  private
  
  def enqueue(event)
    apply(event)
    changes.append(event)

    self
  end
  # ...
end
```

We've added a new instance method named `apply`. This is responsible for calling the correct dynamic method, passing the event as an argument.

The `apply` method is now the first method called when applying, finally bringing the aggregate to the state it expects to be in.

However, this magic needs a bit of help. It needs to understand the name of the event in order to create the dynamic apply methods. This can be acheived in a few ways in Ruby. We'll just make this a class constant called `NAME` and at it to our `CartOpened` event:

```ruby
class CartOpened
  NAME = "CartOpened"

  # ...
end
```

Lastly, we can create the method that will be called when an event is applied:

```ruby
class ShoppingCart
  # ...
  on CartOpened do |event|
    @uuid = event.shopping_cart_uuid
  end
  # ...
end
```


With our aggregates applying events, we are finally we are able to see the result:

```ruby
ShoppingCart.new("test-uuid")
=> #<ShoppingCart:0x0000000135a8ac10 @items=[], @uuid="test-uuid", @changes=[#<CartOpened:0x0000000135a8ab70 @shopping_cart_uuid="test-uuid">]>
```

We can clearly see that the aggregate is applying events correctly, as it has a `uuid`!

### Aggregate Design: Command Methods

TODO: Add link to CQRS

Quite often, Event Sourcing is used in conjunction with [CQRS](CQRS) as they are really a natural fit. EventSoucing allows us to build up Read Projections of our models using a stream of events and CQRS gives us a clear seperation between _writing_ data and _reading_ data.

When writing data, we do so using a _Command_ and when reading data, we do so using a _Query_.

TODO: This definition sucks. Let's improve it.

Commands are a fantastic way of expressing what your business software does and what business criteria is enforced when they are executed. They are often implemented as distinct Objects which are executed by an aggregate. For example:

```ruby
class CloseCartCommand
  attr_reader :shopping_cart_uuid
  
  def initialize(shopping_cart_uuid)
    @shopping_cart_uuid = shopping_cart_uuid
  end
end
```

Another way they can be implemented, is expressing the command as a _command method_ on an aggregate instead of a distinct object. This is the style we will use for our system.

Let's add a command method to add items to our cart and we will start by defining a new event, of course.

```ruby
class ItemAdded
  NAME = "ItemAdded"
  attr_reader :shopping_cart_uuid, :item_name

  def initialize(shopping_cart_uuid, item_name)
    @shopping_cart_uuid = shopping_cart_uuid
    @item_name = item_name
  end
end
```

And now let's define our command method and `apply` handler:

```ruby
class ShoppingCart
  include Aggregate

  attr_reader :items
  
  # ...

  def add_item(item_name)
    enqueue(ItemAdded.new(uuid, item_name))
  end

  # ...

  on ItemAdded do |event|
    @items = @items.append(event.item_name)
  end
end
```

Our command method is named `add_item`. When this is executed against our `ShoppingCart`, it adds the supplied item to the list of items.

### Aggregate Design: Enforcing Bussiness Constraints

CQRS is beyond the scope of this series but helps to understand the role it plays when desining our aggregates as CQRS promotes really healthy object design in complex software. 

One of the critical goals of CQRS is to provide a clear understanding of where a business constraint is enforced and having it enforced in a single location in the code.

Attempting to execute a command should always result in raising an error if the constraint would be broken. This is a critical difference between other architectures such as MVC, where invalid state is allowed in our objects accompanied with a list of errors!

EventSourcing is the persistence and rehydration of our aggregates in the form of events. How these events are created are complemntary to these mechanisms.

Enforcing business constraints happens in our command methods and is rather straightforward:

```ruby
class ShoppingCart
  # ...
  def add_item(item_name)
    fail Errors::ItemAlreadyAdded, uuid, item_name if @items.contains?(item_name)
    
    enqueue(ItemAdded.new(uuid, item_name))
  end
  # ...
end
```

TODO: Add a link to about fail fast

If the item has alreadt been added, [fail fast](fail fast)!

## Conclusion

We've taken a crash course through what Aggregates are and dove deep into designing them for Event Sources systems. We can see how changes are executed against our aggregates with the use of events, and where and how constraints are enforced.

Finally, we touched on why EventSourcing so often goes hand-in-hand with CQRS.

Up next, we will dive into AWS to start persisting and rehydrating our aggretes using DynamoDB!

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
