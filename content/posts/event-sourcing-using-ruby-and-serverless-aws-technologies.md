---
title: Event Sourcing with Ruby and Serverless AWS Technologies
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
draft: false
---

Building software to tackle complex problems can be quite difficult at times both do the the complexity of the problems we are trying to solve and the literature around the solution used to solve them!

This blog series aims at being a pragmatic take on building an EventSourced system leveraging the power of AWS Serverless technologies. It is by no means a complete guide but does show concrete patterns that can be used other architectures other than EventSourcing.

The series will take you through storing Aggregates and their changes as events, aggregate rehydration, publishing new aggregate events to an event stream, and handling them in down stream event handlers.

Our first stop is _Design_.



# Design

Idea of a Shopping Cart
How does event sourcing works.
What the architure in AWS looks like.
What is Change Data Capture

Summary of what Infrastrcture as Code is and what Terraform does (and why I choose not to use Cloudformation)

TODO: Draft some designs of the architure
TODO: Add Improving usage of technologies at the end of every chapter

-----

## Idea of a Shopping Cart

The idea of a Shopping Cart gives us a pretty nice foundation for building an EventSourced system because it is a familiar concept and introduces a temporal model, that helps solves problems _over time_. For example, when shoppers come to your site to purchase some fine merchandise you may want to know when they Add an Item to an Open Cart, so you can suggest related items. Or perhaps, if a cart is still Opened after two weeks, to send them a small reminder.

For this project, we will build a small Shopping Cart system to explore EventSourcing that does two things: Opening a Cart and Adding Items to the Cart.

## How does event sourcing works

TODO: Link to what an aggregate is

EventSourcing is a persistence pattern that, instead of storing Aggregates as whole objects in a database and making updates against them, it stores mutations as a series of events. On the other hand, to fetch an Aggregate from the database, it does not fetch a whole object from the database but rather all related events to the aggregate. 

After these events have been fetched, the Aggregate is rehydrated (rebuilt) by iterating over each event, building up the intended state.

This is very similar to reducing an array of values into a single value. Take an array of hashes for example:

```ruby
events = [{hello: "world"}, {foo: "bar"}]
=> [{:hello=>"world"}, {:foo=>"bar"}]

events.reduce(:merge)
=> {:hello=>"world", :foo=>"bar"}
```

The final state is single structure instead a series of values.


### What problem does it solve?

EventSourcing solves the difficult problem of where a message needs to be published alongside a data change, informing interested parties about that change.

- What should happen to your data change, if publishing the message should fail?
- What should happen to a published message, if the data change fails during transaction commit?

The intention is to provide a solution that does not introduce a [ Two-Phase Commit ]( https://en.wikipedia.org/wiki/Two-phase_commit_protocol ). Even if you could introduce Two-Phase Commits, what happens when one system is exhausted? The entire system could come to an entire standstill.

### How Publishing Works

As odd as it may sound, we are able to leverage the underlying database technology to help with publishing a message! But wait, databases are for storing information, not publishign messages?!

Many clever database designers solved the challenges that come with building a database but introducing some sort of _log of data changes_ which can be to gaurantee data consistency and decrease latency. 

Some examples of this are:
- Write Ahead Log (WAL) in PostgreSQL
- Redo Log in InnoDB (MariaDB, MySQL)
- Journaling in MongoDB

Even more clever, the designers provide programmers the means to _hook_ into these logs for our own needs! These are often called _streams_ and often come first-class such as MongoDB Streams or DynamoDB Streams. However, in some cases like PostgreSQL, some additional tricks are needed to publish data changes outside of the database https://datacater.io/blog/2021-09-02/postgresql-cdc-complete-guide.html.


This process is known as _Change Data Capture_.


# Ruby 
- Basic DynamoDB table
  - None of the Event CDC stuff
  - Basic UUID
  - Include some additional Cloudwatch stuff
- Ruby implementation of an Aggregate
- Ruby implementation of Repo
 - only has two methods
 - Designed to handle the _write_ nature of business requirements and not the read
 - Fetch method implementation
 - Store method implementation
- Implement ShoppingCart and ShoppingCartRepo
- TODO: Add Aggregate Design

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
