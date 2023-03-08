---
title: "SODiR: Part 1 - Types of Service Objects"
date: 2022-10-03
description: TODO
image: images/space-cerqueira.jpg
draft: false
---
_Application Services_
These are objects which provide a public interface for your application, so it’s not unusual for them to expose multiple public methods.
Their responsibility is to carry out the callers request and coordinate internal logic between lower layers, allowing the internal logic to stay internal and decoupled from one another.

These services are a part of the Application Layer.

_Domain Services_
Domain Services carry out busy business logic either by coordinating between objects or through a direct implementation inside the object. Service Objects which directly implement business logic within itself is at risk of violating SOLID, so don’t be afraid to start to decompose service objects behaviours into multiple distinct objects each with single responsibilities and allow the Domain Service to mediate between them.

NOTE: How do we know when is a good time to start splitting up Service Objects? Martin Fowlers REFACTORING provides code Smells, let’s take look there.

Domain Service Objects carry implement only a single feature (sometimes Called Business Rules). For example, “CreateReportService” or “StartMoneyTransfer”

_Infrastructure Services_
Out of all three types of services, Infrastructure Services are the only ones which should not carry any understanding…
