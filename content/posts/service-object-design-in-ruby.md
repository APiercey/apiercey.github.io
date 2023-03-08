---
title: Service Object Design in Ruby (SODR Series)
date: 2022-10-03
description: TODO
image: images/space-cerqueira.jpg
draft: false
---

Service Objective design is a difficult topic to get right. 
Services Objects are a strange breed of design where they name “service” is applied everywhere, under different contexts.
Their code is under stress of extreme churn, often temperamental.
Great Service Object design derives not only from it’s class implementation but from surrounding classes and the techniques they use as well.

I’m writing this series to provide a guide to Service Object design with techniques are recommendations I have picked up over the years.

## What are they and what problem do they solve?
As more features are built into our software, classes that start out with a Single Purpose (SOLID) acquire more responsibilities than they would like. This often results in spaghetti code with impossible-to-follow indirection that leads the debugging engineer to remote areas of the application!

Service Objects are a way of coordinate logic (business or otherwise) between components we would like to stay decoupled (great services objects  also abstracts/hides implementation details that are not needed to be understood to understand the application as a whole).

The name Service is quite confusing. Service Objects are everywhere and they come in different forms ultimately with different responsibilities.
My aim is to demonstrate the different kinds of Service Objects, and when to apply them.

The Fundamentals of Software Architecture  argues there are two kinds of Architecture: Technical oriented and Domain oriented. The great part of using Service Object pattern is it highly applicable to both and often used to solve real world problems.

Technical Architectures organised their components by their technical function.
Domain Architectures organise their components around the business domain they impact.

In this series, we will use a fictitious Application named NAME MEEE, in which it’s architecture is a Layered Architecture. This is probably the most common architecture currently being used.

With this, we will explore the different types of Service Objects and how they can be designed in Ruby, and most importantly, tested!

- [Part One, different types of Service Objects](part-1-types-of-services)
- [Part Two, Dependency Injection and Service Initialisation](part-2-dependencies-and-object-initialisation)
- Part Three, Naming (Intention-Revealing naming)
- Part Four, Testing and fakes
- More to come
