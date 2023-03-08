---
title: Event Sourcing with Ruby and AWS Serverless Technologies - Introduction
date: 2023-03-06
description: Building an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: false
draft: false
useComments: true
disqusIdentifier: "event-sourcing-page-1"
---

Building software to tackle complex problems can be quite difficult at times both do the the complexity of the problems we are trying to solve and the literature around the solution used to solve them!

This blog series aims at being a pragmatic take on building an EventSourced system leveraging the power of AWS Serverless technologies. It is by no means a complete guide but does show concrete patterns that can be used other architectures other than EventSourcing.

The series will take you through storing Aggregates and their changes as events, aggregate rehydration, publishing new aggregate events to an event stream, and handling them in down stream event handlers.

TODO: How to make this link use a hugo dynamic function?

Our first stop is [_Design_](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/design).

## Further Todos:

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
