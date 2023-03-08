---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part One: Design"
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: true
draft: false
useComments: true
disqusIdentifier: "event-sourcing-with-ruby-part-1-design"
---

Idea of a Shopping Cart
How does event sourcing works.
What is Change Data Capture
What the architure in AWS looks like.

Summary of what Infrastrcture as Code is and what Terraform does (and why I choose not to use Cloudformation)

TODO: Draft some designs of the architure
TODO: Add Improving usage of technologies at the end of every chapter

-----

TODO: Add a link somewhere that compares _Capture, Transform, Publish_ to _Extract, Transform, Load_

## Idea of a Shopping Cart

The idea of a Shopping Cart gives us a pretty nice foundation for building an EventSourced system because it is a familiar concept and introduces a temporal model, that helps solves problems _over time_. For example, when shoppers come to your site to purchase some fine merchandise you may want to know when they Add an Item to an Open Cart, so you can suggest related items. Or perhaps, if a cart is still Opened after two weeks, to send them a small reminder.

For this project, we will build a small Shopping Cart system to explore EventSourcing that does two things: Opening a Cart and Adding Items to the Cart.

## How does event sourcing works

TODO: Link to what an aggregate is

EventSourcing is a persistence pattern that, instead of storing Aggregates as whole objects in a database and making updates against them, it stores mutations as a series of events. On the other hand, to fetch an Aggregate from the database, it does not fetch a whole object from the database but rather all related events to the aggregate. 

After these events have been fetched, the Aggregate is rehydrated (rebuilt) by iterating over each event, building up the intended state.

This is very similar to reducing an array of values into a single value. Take an array of hashes for example:

```ruby
aggregate = {name: "CatMeme"}
=> {:name=>"CatMeme"}

events = [{status: "Uploaded"}, {featured: true}]
=> [{:status=>"Uploaded"}, {:featured=>true}]

events.reduce(aggregate, :merge)
=> {:name=>"CatMeme", :status=>"Uploaded", :featured=>true}
```

The final state is single structure instead a series of values.

### What problem does it solve?

EventSourcing solves the difficult problem of where a message needs to be published alongside a data change, informing interested parties about that change.

- What should happen to your changed data, if publishing the message should fail?
- What should happen to a published message, if change fails during transaction commit?

The intention is to provide a solution that does not introduce a [Two-Phase Commit](https://en.wikipedia.org/wiki/Two-phase_commit_protocol). Even if you could introduce Two-Phase Commits, maintaing a Transaction Co-Ordinator comes with many pitfalls and 'gotchas!'. Even simply, what happens when one system in the distributed transaction is exhausted? The entire system most likely will come to an entire standstill. Yuck!

### How Publishing Works

As odd as it may sound, we are able to leverage the underlying database technology to help with publishing a message! But wait, databases are for storing information, not publishign messages?!

Many clever database designers solved the challenges that come with building a database but introducing some sort of _log of data changes_ which can be to gaurantee data consistency and decrease latency. 

Some examples of this are:
- Write Ahead Log (WAL) in PostgreSQL
- Redo Log in InnoDB (MariaDB, MySQL)
- Journaling in MongoDB

Even more clever, the designers provide programmers the means to _hook_ into these logs for our own needs! These are often called _streams_ and often come first-class such as [MongoDB Streams](https://www.mongodb.com/basics/change-streams) or DynamoDB Streams. However, in some cases like PostgreSQL, some additional tricks are needed to publish data changes outside of the database https://datacater.io/blog/2021-09-02/postgresql-cdc-complete-guide.html.


TODO: Add missing link below

This process is known as [_Change Data Capture_](_Change Data Capture_) and often happens in three steps: _Capture, Transform, Publish_.

TODO: Remove transform as a part of the capture step and move it into it's own function


### Example: Change Data Capture in PostgreSQL

TODO: Add Link for SQL Trigger

Change Data Capture in PostgreSQL is possible by leveraging [SQL Triggers](SQL Triggers) so that whenever data is changed, we can require Postgres to execute a function for us. This role of this function is to, well, _capture_ changes, transform them into a universal format (e.g. JSON), and push them to consumers who care about these changes.

![CDC with PostgreSQL](/images/postgres-cdc.jpg)

In an Event Sourcing setup, there is ussually a single consumer and which is the event stream. The trigger will capture new events added to an aggregate and publish them to the stream.


### Example: Change Data Capture in MongoDB

Many databases designers are embracing the Change Data Capture concept and building this as a first-class feature in the database technologies they design. MongoDB is a great example of this.

TODO: Add link to Mongo Streams

Change Data Capture in MongoDB is possibly natively by use [Mongo Streams](Mongo Streams). Internally, changes are captured by leveraging an already built-in feature called _replication_, which is normally used for replicating data from the Primary node to Secondary nodes.

When a change is being replicated, it's "pushed" to a Mongo Stream. From there, consumers can consume these changes.

![CDC with MongoDB](/images/mongodb-cdc.jpg)

Like PostgresQL, in an Event Sourcing setup, there is ussually a single consumer, being the event stream. In the example above, the data still needs to be transformed from the format of how MongoDB publishes changes, to the format we expect from our events.

## What the Architecture in AWS Will Look Like

TODO: Add link to serverless tech definition

Our goal is to use only [serverless](serverless) technologies. This will help us scale on demand and be highly availalble but also, in my opinion, Event Sourcing is largely a _infrastrcutre_ heavy pattern and there is a large over head in maintaining this infrastrcture. AWS does a great job in releiving Application and DeveOps engineers from this responsibility.

### Lambda

Lambda will be our computer power that is used to:
1. Handle our incoming client requests regardless if they are coming from an API, background worker, or another piece of the infrastrcture.
2. Provide event handlers for events published on our Event Stream.
3. Transform captured events from DynamoDB and publish them to Kinesis. More on this below.

### DynamoDB and DynamoDB Streams

DynamoDB will be our database. It will provide tables for our aggregates to store events and streams to help publish changes.

DynamoDB is a great choice because it is a key-value store that will allow us to store unstructured events and is highly scalable to unexpected peaks of traffic.

### Kinesis Streams

Kinesis will act as our event stream. Events captured from DynamoDB tables will be published here, becoming available to our event handlers.


### Cloudwatch Logs

While not part of our solution, our lambda will log to Cloudwatch, so we can inspect any errors.

## The Architecture

Requests will flow into Lambdas hosting our business logic. When this happens, our application needs rehydrate our aggregates to execute a business function, rehydration happens by fetching events from a _DynamoDB table_ and not from the Kinesis stream.

In this regard, you can think of Kinesis stream as the "all-events-stream" and each DynamoDB as a stream for each "aggregate".

Change Data Capture is achieved by using DynamoDB Streams. Changes are _Captured_ to an internal stream and handled by a Lambda to _Transform_ into JSON. Finally, the Lambda will _Publish_ them to our Kinesis stream.

Lastly, event handlers will be built using a Lambda and a Kinesis trigger.

TODO : Update this to be more simple and emphasis Capture, Transform, Publish
![Architecture in AWS](/images/event-sourcing.jpg)


## Infrastructure as Code and Terraform

We're coming to the end of our first step in this series. However, it's probably critical to breifly talk about _Infrastrcture as Code_  as it will be at the _core_ of what we write.

Building infrasstructre by hand is a very miticiously task and often very error prone due to Layer 8 mistakes.

If the same infrastrcure needs to be built within multiple environements, it can become seriously time innificient to do this by hand!

This is where Infrastrcure as Code (IaC) comes into play. IaC is code which expresses infrastrcture, ussually in a highly declaritive language.

Some examples of IaC are:
- Chef, a Ruby DSL
- Ansible, a Python DSL
- Cloudformation, AWS propriety technology, written in either JSON or YAML
- Terraform, it's own language, implemented in GoLang.

Not all IaC's are created equal! For this project, we'll use Terraform as in my experience, it does a great job at acheiving what it's meant to do while staying out of your way. Additionally, it works across many different Cloud providers and a highly reusable skill.

An example of how powerful Terraform can be, it's possible to boot up a Postgres database in any environment with two simply steps:

First, add the following declaring to a file name `database.tf` (the file name does not particualrly matter):

```terraform
resource "aws_db_instance" "my-psql-d" {
  allocated_storage    = 10
  db_name              = "my_postgres_db"
  engine               = "postgresql"
  instance_class       = "db.t3.micro"
  username             = "super_secure_username"
  password             = "super_secure_password"
}
```
Secondaly, execute the following command in your directoy that hosts your terraform code:
```bash
$ terraform apply
```

Viola! You now have a Postgres database running in our AWS account. How wicked is that??

_NOTE: In case you do try this, you can execute `terraform destroy` to remove the database and save yourself some money ;)_

## Conclusion

We've covered the design of our Event-Sourcing application-to-be and the technologies we will use. 

Next stop, will by _Ruby and Aggregates_ where we start to implementing our design.

# Ruby and Aggregates
- At this time of writing, AWS only supports Ruby 2.7 natively. So we wont use fancy new 3.x features
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
