---
title: "Event Sourcing with Ruby and AWS Serverless Technologies - Part Four: Change Data Capture"
date: 2023-03-06
description: Buulding an Event-Sourced application in Ruby using Lambda, DynamoDB, Kinesis, S3, and Terraform
image: images/event-sourcing.jpg
showTOC: true
draft: true
useComments: true
disqusIdentifier: "event-sourcing-with-ruby-part-4-change-data-capture"
---

# Change Data Capture
- DynamoDB Streams and what are they
- Implement OpenCart, GetCart, and AddItem Lambdas
- Introduce Lambda to capture changes
  - Pluck new events from Aggregate changes
  - Simple event logging for now

-----

This is part four of an ongoing series where we build an EventSourced system in Ruby using AWS Serverless Technologies.

We will use DynamoDB Streams and Lambda to facilitate the Change Data Capture Process.

## DynamoDB Streams

[DynamoDB Streams](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html) is a streaming technology part of the DynamoDB suite, that captures changes to a table and makes them available for up to 24 hours to consumers. The data is time-ordered and availalbe in near real-time.

After capturing changes, we will eventually push them to Kinesis using Lambda.

### Configuring Streams

In order to enable streams on our DynamoDB tables, we need to add a our configuration
Streams can easily be enabled in our DynamoDB tables by setting `stream_enabled` to true. We'll also need to tell DynamoDB what sort of values we're interested in seeing by setting `stream_view_type`.

```terraform
resource "aws_dynamodb_table" "es_table" {
  name     = var.table_name
  hash_key = "Uuid"

  attribute {
    name = "Uuid"
    type = "S"
  }

  read_capacity = 1
  write_capacity = 1

  # Added configuration
  stream_enabled = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}

```

`stream_view_type` determines what information is available in our stream and accepts a [few different possibilities](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_StreamSpecification.html). In order to understand what new events have been published, we'll need to use `NEW_AND_OLD_IMAGES`, as this will provide two lists of events from before and after the change. In order to determine which new events to publish, we can differentiate between them.

### About DynamoDB Kinesis Streams

DynamoDB can actually push data into Kinesis, nativly. So why the extra step?

DynamoDB supplies it's changes as a complete data set and not just the difference.
- Additionally, it's possible to persist multiple events with one change. We want _one_ record in Kinesis to be _one_ event.

## Conclusion

TODO

# Kinesis and Downstream Event Handlers
- What is Kinesis
- Lambda that captures changes should publish to Kinesis
  - Map DynamoDB to JSON
  - PutRecord/s
- EventHandler to handle 
- Publish to S3 for long term storage
- Share idea on introducing a lambda to replay events
- Improving Kinesis https://dashbird.io/blog/lambda-kinesis-trigger/
