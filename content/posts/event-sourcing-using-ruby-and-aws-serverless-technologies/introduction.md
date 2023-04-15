---
title: Event Sourcing with Ruby and AWS Serverless Technologies - Introduction
date: 2023-04-01
description: Building an event sourcing application in Ruby with the power of AWS Serverless technologies
image: /images/aws-eventsourcing/complex-architecture.jpg
showTOC: false
draft: false
useComments: true
disqusIdentifier: "jlhsac4qln"
keywords:
  - event sourcing
  - ruby
  - aws
  - serverless
---

Developing software that solves complex problems can be challenging at times. Often, the literature around solving these problems makes it even harder to see the solution through the trees!

This blog series aims at being a pragmatic take on building an event sourcing system by leveraging AWS Serverless technologies. It is by no means a complete guide but provides concrete patterns that you can use while building your own. Moreover, you'll find that these patterns can be used in other architectures as well.

We will first walk through the process of storing aggregates and their changes as events, then rebuilding aggregates from its past events. Afterwords, we will see how publishing new aggregate events to an event stream works and how downstream event handlers receive these events.

Fundamentally, that is the core of what event sourcing does. However, in most event sourcing systems, your event handlers will need to replay events - so we'll look at how that can be achieved as well.


## Table of Contents:
1. [Design](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/design): Design of an event sourcing system and how Change Data Capture is achieved.
2. [Aggregate Design in Ruby](/posts/event-sourcing-using-ruby-and-aws-serverless-technologies/aggregate-design): How aggregates are designed and the role events play in altering their state.
3. _Waiting to be published_.
