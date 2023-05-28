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
TODO: Is this the real next chapter or the other one with the same name?!

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

[DynamoDB Streams](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html) is a streaming technology part of the DynamoDB suite, that captures changes to a table and makes them available for up to 24 hours to consumers. The data is ordered by timestamp and availalbe in near real-time.

After capturing changes, we will eventually push them to Kinesis using Lambda.

### Configuring Streams

In order to enable streams on our DynamoDB tables, we need to add a our configuration
Streams can easily be enabled in our DynamoDB tables by setting `stream_enabled` to true. We'll also need to tell DynamoDB what sort of values we're interested in seeing by setting `stream_view_type`.

```terraform [no_los[14,15]]
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
  # TODO highlight these lines
  stream_enabled = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}

```

`stream_view_type` determines what information is available in our stream and accepts a [few different possibilities](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_StreamSpecification.html). In order to understand what new events have been published, we'll need to use `NEW_AND_OLD_IMAGES`, as this will provide two lists of events from before and after the change. In order to determine which new events to publish, we can differentiate between them.

### About DynamoDB Kinesis Streams

DynamoDB can actually push data into Kinesis, nativly. So why the extra step?

DynamoDB supplies it's changes as a complete data set and not just the difference. This makes it impossible to understand new events. Additionally, it's possible to persist multiple events with one change. We want _one_ record in Kinesis to be _one_ event, therefore, we need to transform the captured data change to meet our needs.

## Adapter Lambda

To transform our captured data, we'll subscribe to our tables Stream using Lambda. We'll add a few bells and wistles to make future changes easier, such as logging. We will create a terraform module for launches our Lambdas.

### Basic Lambda Module

Let's start simple, with a module named `lambda`.

Our module accepts a `source_dir` which is where the source code is defined, a function name, and a runtime.

```terraform
# lambda/variables.tf

variable "source_dir" {
  type = string
}

variable "name" {
  type = string
}

variable "runtime" {
  type = string
}
```

Our function code is defined as so:

```terraform
# lambda/function.tf

data "archive_file" "lambda_archive" { 
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "./packaged_functions/${var.name}.zip"
}

resource "aws_lambda_function" "main" {
  filename      = "./packaged_functions/${var.name}.zip"
  function_name = var.name
  role          = aws_iam_role.iam_for_lambda.arn # More on this below
  handler       = var.handler

  source_code_hash = data.archive_file.lambda_archive.output_base64sha256

  runtime = var.runtime
}
```

We package up and deploy our lambda by archiving the source directory and providing the archive as a filename.

Finally, in order to execute our lambda, the _Lambda_ Service - by that I mean _AWS_ itself - needs permission to execute our lambda. We can create a new IAM Role which AWS Lambda is allowed to _assume_.

```terraform
# lambda/function.tf

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "${var.name}-role-for-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}
```

### Adapter Code

We'll extend our `event_source_table` module to create an adapter per table.

First, here is the ruby code

```ruby
# event_source_table/scripts/dynamo_to_kinesis_adapter/main.rb
require 'json'
require 'base64'
require 'aws-sdk-dynamodbstreams'

def pluck_new_events(event)
  events_matrix = Aws::DynamoDBStreams::AttributeTranslator
    .from_event(event)
    .map do |record|
      new_image_events = record.dynamodb.new_image.fetch("Events")
      old_image_events = (record.dynamodb.old_image || {}).fetch("Events", [])

      new_events = new_image_events[old_image_events.count..]
    end

  events_matrix.flatten
end

def handler(event:, context:)
  events = pluck_new_events(event)
  
  puts events.inspect

  { event: JSON.generate(new_events), context: JSON.generate(context.inspect) }
end
```

First, we pluck _all new events_ from the provided DynamoDB event **Records** - Records being _plural_. This is because Streams will push a batch of changes at a time. This happens by comparing slicing a range of events from the new image event list by using the old image events lists length:

```ruby
new_events = new_image_events[old_image_events.count..]
```

We're able to achive this becuase we've explicly requested DynamoDB to provide both the `NEW_AND_OLD_IMAGES`.

Lastly, we'll just log our events. After we've _actually_ implemented our Kinesis streams, we'll come back and publish our events to it.

### Deploying our Lambda

We're now ready to actually deply our adapter function. Let's define it using terraform in our `event_source_table` module:

```terraform
# event_source_table/adapter_function.tf

module "dynamo_to_kinesis_adapter" {
  source = "../lambda"

  source_dir = "event_source_table/scripts/dynamo_to_kinesis_adapter"
  name = "${var.table_name}_to_kinesis_adapter"
  runtime = "ruby2.7"
  handler = "main.handler"
}
```

Executing `terraform apply` will now create our function! Wonderful. Now all that is left is to create the subscription between the DynamoDB Stream and our Lambda.

To do so, we'll need two things:
- The subscription itself - which is called a _mapping_.
- Provide Lambda permissions to receive data from our DynamoDB Streams.

#### Extending Lambda 
We'll extend our Lambda module to allow passing in a custom IAM Policy document that can be attached to our Lambda role. This way, any lambda can be tailored to it's needs.

```terraform
# lambda/variables.tf

variable "custom_policy_json" {
  type = string
}
```
```terraform
# lambda/custom_policy_attachment.tf

resource "aws_iam_policy" "lambda_custom_policy" {
  name        = "${var.name}-custom-policy-doc"
  path        = "/"
  description = "Custom Policy Document"
  policy      = var.custom_policy_json
}

resource "aws_iam_role_policy_attachment" "lambda_custom_policy_attachment" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.lambda_custom_policy.arn
}
```

Our lambda now expects an IAM Policy _document_ and with it, will create and attach the Policy on the Lambda.

We can now extend our Adapter lambda to use a `custom_policy_json` document.

```terraform
# event_source_table/adapter_function.tf

module "dynamo_to_kinesis_adapter" {
  source = "../lambda"

  source_dir = "event_source_table/scripts/dynamo_to_kinesis_adapter"
  name = "${var.table_name}_to_kinesis_adapter"
  runtime = "ruby2.7"
  handler = "main.handler"

  TODO: Highlight
  custom_policy_json = data.aws_iam_policy_document.dynamo_to_kinesis_lambda_policy_data.json

  variables = {
    kinesis_event_stream = var.kinesis_event_stream_name
  }
}

data "aws_iam_policy_document" "dynamo_to_kinesis_lambda_policy_data" {
  statement {
   effect = "Allow"

   actions = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]

   resources = ["arn:aws:dynamodb:*:*:*"]
  }
}
```

#### Defining the Subscription

A simple mapping between DynamoDB and Lambda:

```terraform
# event_source_table/adapter_function.tf

resource "aws_lambda_event_source_mapping" "example" {
  event_source_arn  = aws_dynamodb_table.es_table.stream_arn
  function_name     = module.dynamo_to_kinesis_adapter.function_arn
  # TODO: Actually.. what happens if there is a backlog of events unprocessed and this is run?
  starting_position = "LATEST"
}
```

Viola! Executing `terraform apply` will now create a subscription between our DynamoDB Stream and our Lambda. The Lambda has permissions to receive data from DynamoDB Streams and will log new events.

## Application Lambdas

Considefing we are already able to Persist and Rehydrate aggregates, we have everything we need to start building a full application. Let's build a few additional Lambdas to be able to start manually testing our setup and see new events being logged.

To do this, we will define:
- A Lambda to Open a Cart
- A Lambda to Add an Item to an existing cart
- Extend Lambdas to have log CloudWatch log groups

Additionally, we'll encapsulte our logic into separate classes away from our Lambdas, leaving the Lambdas only responsible for instantiation and execution.

### CloudWatch Log Groups

CloudWatch Logs are a great way for logging our serverless infrastructure. Lambda comes equipped with the functionality to log directly to CloudWatch. All it requires is the correct permissions and for a Log Group to exist.

Firstly, let's create a log group.

```terraform
# lambda/cloudwatch.tf

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${var.name}"

  retention_in_days = 1

  lifecycle {
    prevent_destroy = false
  }
}

```

Done! Now let's give Lambda permissions to log to CloudWatch:

```terraform
# lambda/cloudwatch.tf
# ...

data "aws_iam_policy_document" "log_policy_data" {
  statement {
    effect = "Allow"

    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]

    # TODO: Specific log group?!
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_policy" "log_policy" {
  name        = "${var.name}_log_policy"
  path        = "/"
  description = "IAM policy for accessing Kinesis from a lambda"
  policy      = data.aws_iam_policy_document.log_policy_data.json
}

resource "aws_iam_role_policy_attachment" "log_policy_attachment" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.log_policy.arn
}
```
Done! Now any logging statements, failures, or execution messages will appear in our log group.

### Domain Services

We'll encapsulate our business logic into classes that know nothing about the infrstrature it runs on (Lambda), nor how to instantiate it's own dependencies.

#### OpenCart
```ruby
require 'securerandom'

module DomainServices
  class OpenCart
    def initialize(shopping_cart_repo)
      @shopping_cart_repo = shopping_cart_repo
    end

    def call
      shopping_cart = ShoppingCart.new(SecureRandom.uuid)
      @shopping_cart_repo.store(shopping_cart)
      shopping_cart
    end
  end
end
```

#### AddItem

```ruby
module DomainServices
  class AddItem
    def initialize(shopping_cart_repo)
      @shopping_cart_repo = shopping_cart_repo
    end

    def call(shopping_cart_uuid, item_name)
      shopping_cart = @shopping_cart_repo.fetch(shopping_cart_uuid)
      shopping_cart.add_item(item_name)

      @shopping_cart_repo.store(shopping_cart)

      shopping_cart
    end
  end
end
```

#### Get Cart
```ruby
module DomainServices
  class GetCart
    def initialize(shopping_cart_repo)
      @shopping_cart_repo = shopping_cart_repo
    end

    def call(shopping_cart_uuid)
      @shopping_cart_repo.fetch(shopping_cart_uuid)
    end
  end
end
```

### Executing Using Lambdas
In order execute our Domain Services using Lambdas, we'll need to define our lambdas using terraform. Additionally, because our `ShoppingCartRepo` is using DynamoDB, we'll need to make sure our Lambdas can access DynamoDB.

#### Extending Lambda
Lambdas most likely differ in their requirements. To have a flexible approach, we can extend our lambda module to accept a custom IAM document.

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
