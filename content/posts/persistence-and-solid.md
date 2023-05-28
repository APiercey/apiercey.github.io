---
title: "Persistence and SOLID"
date: 2023-05-28
description: Reviewing persistence of objects in in regards to SOLID.
image: images/event-sourcing.jpg
showTOC: true
draft: true
list: "never"
useComments: true
disqusIdentifier: "mnt47ql28ny4c"

---

## A Breif Word About Persistence

From the previous article about Designing Aggregates in Ruby, nothing obvious about persistence was included in the design. This is largely intentional.

In Domain-Driven Design circles, aggregates being resposible for _how_ they are persisted is a faux-pas. Why is that?

Disregarding DDD, let's examine what that really means by [cross examining SOLID](https://en.wikipedia.org/wiki/SOLID):

> The **S**ingle-responsibility principle - _"There should never be more than one reason for a class to change." In other words, every class should have only one responsibility._

Often changing how objects are persisted results in altering the behaviour of an objects true responsibilities. Objects tend to reflect their underlying data persistence needs rather than their domain needs.

For example, when considering to using an ORM such as [ActiveRecord](https://guides.rubyonrails.org/active_record_basics.html), the engineer is obliged to expose data access methods which reflect the underlying database table. Additionally, ActiveRecord forces the data to be stored in a way that ActiveRecord prefers and not exactly in a way that is beneficial.

> The **O**pen–closed principle - _"Software entities ... should be open for extension, but closed for modification."_

To meet common but complex persistence needs, it almsot always require breaking the Open-Closed principle. 

Consider the complexity of serialization. An `Order` object holds it's line items in a `line_items` attribute. When accessed, it plainly returns a list of `LineItem`s. In order to combat getting around the domain responsibilties of the object, the `Order` must be modified to declare that the `line_items` attribute must be serialized when being persisted. At worse, the `Order` object must implement this behaviour itself.

Such behaviour can be encapsulated into a Class dedicated for peristing an `Order` and it's `LineItem`s.

> The **L**iskov substitution principle - _"Functions that use pointers or references to base classes must be able to use objects of derived classes without knowing it."_

I would argue this one isn't broken. There would be a consistent interface across concrete objects for data access and no contracts would be broken.

Still, this is true only in isolation.

> The **I**nterface segregation principle: _"Clients should not be forced to depend upon interfaces that they do not use."_


When an object is used in client code, the client should not have to understand the underlying persistence mechanism regardless of how it is persisted.

However, consider a class which uses an object that is responsible for it's own storage through a method named `save`.

A highly complex object with a few dozen attributes, some with nested objects and their own attributes may take slightly longer to persted than expected (remember, ORMs have difficulty in persisting 

Think about who is the first _client_ of your code? Your first answer should be it's _tests_ then any business related code which fetching the object from storage, executes a method, then attempts to persist it.

By coupling persistence to an object, your object's unit tests are forced to use methods it would not normally use. Here are two examples:
- Tests are expected to make sure invalid data is not persisted. What does that have anything to do with the object's intended behaviour?
- Tests are expected to setup the object (and possibly it's dependencies) in a desited state when testing previously persisted objects, forcing the client to use methods it normally would not need to use.

> The **D**ependency inversion principle: _"Depend upon abstractions, [not] concretions."_



