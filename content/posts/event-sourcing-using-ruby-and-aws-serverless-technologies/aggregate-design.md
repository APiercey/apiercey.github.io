---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Two: Aggregate Design"
date: 2023-04-15
description: How Aggregates are designed and the role events play in altering their state.
image: /images/aws-eventsourcing/elbphilharmonie-hamburg.jpg
imageCredit:
  url: https://instagram.com/moabitdottir?igshid=NTc4MTIwNjQ2YQ==
  text: Elbphilharmonie Hamburg by Moabitdottir
showTOC: true
draft: false
useComments: true
utterenceIssueNumber: 3
keywords:
  - event sourcing
  - ruby
  - aggregates
  - cqrs
  - event driven architecture
  - read projections
  - meta-programming
---

_This is the second part in an on-going blog series about [building an event sourcing system in Ruby using AWS Serverless technologies](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/introduction)._

Aggregate design is at the center of how event sourcing systems operate. They encapsulate our events into a greater meaning than the sum of its parts.

We will implement our ShoppingCart aggregate, the events it publishes, and how these events are applied to alter its state. This will be the foundation of our system.

## Aggregate Crash Course
Let's briefly discuss what they are and which problem they solve.

Aggregates are groups of objects that enforce business constraints with **one** acting as the root object. The root object acts as the spokesobject for the others and nothing can access the internal objects without traversing the root object first. In DDD nomenclature, these objects are composed of Entities and Value objects.

This means things _outside_ of the aggregate cannot reference an internal object directly - it must always ask the root object for access to its internal objects.

<img src="/images/aws-eventsourcing/aggregate.jpg" width="400px" style="display: block; align-self: center; margin-left: auto; margin-right: auto;" />

For example, consider a ledger system that carries Accounts and Bookings. The diagram below shows a Booking Monitoring Class that needs access to an account's bookings. On the left, the Booking Monitoring Class gains access to these bookings by requesting them through the Aggregate Root entity's public interface. While on the right, the same class incorrectly gains access by circumventing the Aggregate Root and accessing bookings directly.

In the example on the right, the aggregate provides _weak_ protection against direct access.

![Aggregate Access](/images/aws-eventsourcing/aggregate-access.jpg)

This has several fantastic benefits.

First, meaningful relationships between objects in your domain are formed, instead of ones that are logically derived, making your domain model more expressive.

Second, because external entities must always interact through the aggregate root, system constraints must always be located within an aggregate. This gives the application's critical rules a singular home and protects multiple (and often different) implementations of a rule throughout an application.

Lastly, an entire aggregate is treated as a _object collection boundary_. These objects live together and their state is singular, persisted and rehydrated from the data store as a single cohesive unit. This provides assurance the state is fully loaded and ready. 

```ruby
account = AccountRepository.fetch(account_identifier)
=> #<Account @uuid="..." @bookings=[#<Booking ...>, ...]>

# account traverses through the ledger object 
account.bookings
=> [#<Booking ...>, ...]
```

The account is the gatekeeper for all business logic. If we need to execute logic against a booking, we must go through the account:

```
account.revert_booking(booking_uuid)
=> #<Account @uuid="..." @bookings=[#<Booking ...>, ...]>
```

Our Account aggregate enforces one additional rule; **a booking cannot exist without being associated with an account**. As this is intentional, we must _neglect_ to create the means of fetching bookings into memory.

If you have further interest in aggregate design, I highly recommend the following articles:

- https://medium.com/ssense-tech/ddd-beyond-the-basics-mastering-aggregate-design-26591e218c8c
- https://martinfowler.com/bliki/DDD_Aggregate.html

## Aggregates in Ruby

Like other architectures born from circles practicing [Domain-Driven Design](https://en.wikipedia.org/wiki/Domain-driven_design), event sourcing focuses on modeling software to match a domain by taking critical concepts given to engineers by domain experts.

It achieves this by removing the burden of model objects aware of data persistence and elevating facts into events.

Often, the flow of executing business logic in event sourcing looks like this:

An aggregate is firstly retrieved from its repository class. Next, a method is executed to carry out a portion of business logic, and in doing so, _publishes_ an event. Whenever an event is published, the aggregate immediately _applies_ it against itself, changing its own state. 

Finally, the aggregate is persisted using its repository class. Published events are pushed to an event stream.

This means that:
- Methods for executing business logic are responsible for _enforcing_ the rules (E.g. Account balance cannot go below zero!)
- For every action that modifies an aggregate, there is an event.
- Newly published events to an aggregate are stored in memory, waiting to be persisted.
- Aggregates will publish many events over their lifetime.

### Aggregate Design: Defining a ShoppingCart

Our shopping cart will be simple: You can open a shopping cart and add items to it. We'll start with a tiny class definition.

```ruby
class ShoppingCart
  attr_reader :items
end
```

Now, we're ready to explore publishing our first event.

To create an aggregate, it needs two things:
- An identifier, ussually a [UUID](UUID)
- An event which signifies the _starting_ event of that aggregate. In the CRUD world, this is the _creation event_.

### Aggregate Design: Events

Events themselves are simple. They are static structures that describe _facts_ that have happened. They follow only a few rules:

**_They are immutable._**

**_They are named in the past tense._**

**_They describe a meaningful concept in the domain._**

Let's define our first event.

```ruby
class CartOpened
  attr_reader :shopping_cart_uuid

  def initialize(shopping_cart_uuid)
    @shopping_cart_uuid = shopping_cart_uuid
  end
end
```

Simple and neat. When a `CartOpened` object is instantiated, its members cannot be altered. Additionally, its name is in the past tense and describes a core behaviour of our system.

### Aggregate Design: Publishing Events

Let's implement just enough of our first aggregate to publish our event.

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

Our `aggregate` module will host the abstract behaviour of all aggregates. It's responsible for managing `changes` as events and the aggregate `uuid`.

Whenever an event is queued to be published using the `enqueue` method, it stores that event as a `change`. We will see how these changes can be applied and published later.

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

When our `ShoppingCart` is instantiated, it will generate a `CartOpened` event and queue this change to be published.

```ruby
ShoppingCart.new("test-uuid")
=> #<ShoppingCart:0x0000000155b7cd60 @items=[], @changes=[#<CartOpened:0x0000000155b7cd10 @shopping_cart_uuid="test-uuid">]>
```

We can see a change has been queued, waiting to be applied. We are now ready to move forward with the right foundation.

### Aggregate Design: Applying Events

Our ShoppingCart aggregate understands events and can queue them, but lacks the means to alter its own state. As an example from the step above, it has no `uuid`. Let's expand our `aggregate` module to start applying events.

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

Now we must define how these events are applied to our `ShoppingCart`.

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

There is a fair bit of meta-programming happening here, so let's explore what is happening under the hood.

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

When the `Aggregate` module is included into a class, Ruby will execute the `included` method at run time, [passing in the base class](#hl-7-2). This method accomplishes two things:

First, it ensures there is an [instance member named `uuid`](#hl-7-4) and it is only readable.

Second, it defines a new class method named `on` which accepts two arguments, an event class object and a block. 

When the `on` method is called, it is responsible for defining a dynamic method _at run time_ that accepts an event class and a block. When this dynamic method is called, it executes the supplied block. We will see how this works below.

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

We've added a new instance method named `apply`. It is responsible for calling the correct dynamic method, passing the event object as an argument.

Additionally, the `apply` method is now the [first method called when applying](#hl-10-13), finally bringing the aggregate to the state it expects to be in.

However, this magic needs a bit of help. It needs to understand event name in order to create the dynamic apply methods. This can be achieved in a few ways in Ruby. We'll be simple and add a class constant called `NAME` to our events:

```ruby
class CartOpened
  NAME = "CartOpened"

  # ...
end
```

You may derive this from the class name as well.

Lastly, we can create the apply method that is called when an event is applied by using the `on` method.

```ruby
class ShoppingCart
  # ...
  on CartOpened do |event|
    @uuid = event.shopping_cart_uuid
  end
  # ...
end
```

With our aggregates applying events, we are finally we are able to see the result.

```ruby
ShoppingCart.new("test-uuid")
=> #<ShoppingCart:0x0000000135a8ac10 @items=[], @uuid="test-uuid", @changes=[#<CartOpened:0x0000000135a8ab70 @shopping_cart_uuid="test-uuid">]>
```

We can clearly see that the aggregate applies events correctly, as it has the correct `uuid`.

### Aggregate Design: CQRS Intermission

Quite often, event sourcing is used in conjunction with [Command-Query-Responsibility-Segregation](https://martinfowler.com/bliki/CQRS.html) (CQRS) as they represent a natural fit.

CQRS gives us clear seperation between _writing_ data and _reading_ data with Commands executing a set of business functions and Queries retreiving information.

Event sourcing provides event streams in which a specialized set of event handlers called _Read Projections_ subscribe to.

[Read Projections](https://event-driven.io/en/projections_and_read_models_in_event_driven_architecture/) holds the responsibility of understanding events in the domain and transforming them into something readable. Often this is building up data in an SQL datasbase. However, the primary benefit is that it is possible to run as many Read Projections as you require.

Often, this is used to meet different querying needs. For example, you may have two Read Projections: one for inserting data into an SQL database for querying on the _read_ side of the application and another for inserting into a CSV file used in reporting.

![Multiple Read Projections](/images/aws-eventsourcing/cqrs-read-projections.jpg)

By elevating the _read_ requirements out of objects used for enforcing and executing our business logic, we gain a _write model_ free of this extrenuous burdon.

Commands are an effective way of expressing what your domain is designed to achieve and which business rules are enforced when they are executed. They are often implemented as distinct objects executed in an aggregate. For example, given this command exists:

```ruby
class CloseCartCommand
  attr_reader :shopping_cart_uuid
  
  def initialize(shopping_cart_uuid)
    @shopping_cart_uuid = shopping_cart_uuid
  end
end
```

This could be executed using an aggregate. In doing so, an event would be published and downstream event handlers (including Read Projections) would have a chance to react.


```ruby
class CloseCartCommandHandler

  # Our repo is initialized externally
  def initialize(shopping_cart_repo)
    @shopping_cart_repo = shopping_cart_repo
  end
  
  def handle(command)
    shopping_cart = @shopping_cart_repo.fetch(command.shopping_cart_uuid)
    
    # An event is published but not persisted
    shopping_cart.execute(command)
    
    # An event is persisted and pushed into the event stream
    @shopping_cart_repo.store(shopping_cart)
  end
end

```

### Aggregate Design: Command Methods

Another way Commands can be implemented, is by expressing the command as a method on an aggregate instead of a distinct object. These are called _command methods_.

The penalty in doing so, is we lose one degree of expressivness in our model. However, it becomes simpler. 

We will use this style for our commands as our focus is on _event sourcing_ rather than Command objects. You may want to adopt a fuller Command object in your own system if the business rules become complex.

Let's add a command method to add items to our cart. We will start by defining a new event.

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

Now the command method and `apply` handler.

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
    @items.append(event.item_name)
  end
end
```

The newly command method is named `add_item`. When it is executed against our `ShoppingCart` aggregate, it enqueues an `ItemAdded` event to be published. Under the hood, this event is applied by dynamically looking up the correct `apply` handler.

The `apply` handler will append the item to the aggregate's list of items.

### Aggregate Design: Enforcing Business Constraints

CQRS is beyond the scope of this series. However, is helps to understand the role it plays when designing our aggregates as CQRS promotes really healthy object design in complex software. 

One of the critical goals of CQRS is to provide a clear understanding of where a business constraint is and having it enforced in a single location in the code.

Attempting to execute a command should always result in raising an error if the constraint is broken. This is a critical difference between other architectures such as MVC, where invalid state is allowed in our objects often accompanied by a list of errors.

At its root, event sourcing is specifically about the persistence and rehydration of our aggregates by using a collection of events. How its events are created is only an adjunct to these mechanisms.

Enforcing business constraints happens in our command methods and is straightforward.

```ruby
class ItemAlreadyAdded < StandardError
  def initialize(uuid:, item_name:)
    @msg = "#{item_name} has already been added to cart #{uuid}!"
  end
end
```

```ruby
class ShoppingCart
  # ...
  def add_item(item_name)
    fail ItemAlreadyAdded, uuid: uuid, item_name: item_name if @items.contains?(item_name)
    
    enqueue(ItemAdded.new(uuid, item_name))
  end
  # ...
end
```

If an item is already added, raise an `ItemAlreadyAdded` error.

The idea behind this is the ability to _Fail Fast_. Any input which puts the system into an invalid state must fail [_"immediately and visibly"_](_https://www.martinfowler.com/ieeeSoftware/failFast.pdf_).

## Conclusion

We've taken a crash course in what aggregates are and dived deep into their design for event sourcing systems. We can see how changes are executed against our aggregates with events, and where and how constraints are enforced.

Finally, we touched on why event sourcing so often goes hand-in-hand with CQRS.

You may go back to the [introduction page](../introduction) or directly to the next article; [The Event Store and DynamoDB](../event-store-dynamodb-tables) where we introduce the event store in real detail and it's first component.
