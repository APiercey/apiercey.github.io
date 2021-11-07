---
title: Building a Simple Database
date: 2021-08-09
description: What does it take to build a database? Exploring the minimum design required to implement a simple NoSQL database and examine the complexity databases are required to deal with.
image: images/space-cerqueira.jpg
draft: false
---

**EDIT: After digesting what I have learned from Golang and this project, I have largely rebuilt RygelDB. I'll update this blog article once I find the time.**

A colleague once said to me, _"Let's learn Rust and build a NoSql Database! It's easy!"_

Through group learning sessions, we did learn Rust but we never did build that database. Unfortunately, the precious time we had was consumed by other responsibilities, and after some years, we no longer have delight of working together as he is currently working on some other seriously cool stuff, elsewhere!

Still, his words stuck with me over the years and scratched at the back of my head - _"Is it truly so easy?"_

## TL;DR Show Me the Code
The result of exploring this topic is [RygelDB](https://github.com/APiercey/RygelDB). A NoSQL document store using commands to store and query documents.

## Gophers by Land, Crustaceans by Sea

Golang is a hot topic for my team and I. We have chosen to incorporate the language into our toolbox to build better software in the neo-Banking domain.

For this reason, I've chosen to build a NoSql database - dubbed after [sparky Rygel](https://farscape.fandom.com/wiki/Rygel_XVI) - in Golang over Rust purely for a learning exercise and become more familiar with the Golang perspective of Software development.

## Functionality
In the beginning, my imagination ran a bit wild and I started drafting a distributed datastore with read-replica support, supported by a series of stored events pushed to read-nodes, with all the bells and whistles that come with distributed systems allowing for scalling-on-demand and... and then scope-creep slithered into view and introduced me to it's ugly-cousin named _complexity_. So I put the fancy ideas away for a rainy day.

So then, what sort of functionality would be considered minimum for a database? Surely persistence and querying but what about things such as indices, cursors, triggers, or projected-views? What is taken for granted that may not come to mind right away, such as mutli-tenancy? Would _read-replica_ be considered a miniumum given? Perhaps most, if not all of these things, could be considered the _bells and whistles_ to a shiny new database.

In any given system, an Engineer produces software that starts a connection to the database, queries for already persisted data, make a decision with the aquired data, and then make either alter that data or query for more. Ultimately, closing the connection freeing up resources for the next connection.

Additionally, the Engineer probably does not want malicious attackers to gain access to their application data.

With this scenario in my, I had decided the minimum feature set the database would have is:
1. Storing data. I preffered something simple and went with JSON documents.
2. Querying is needed - but nothing complex outside of a few "and" statements.
3. Updating and removing JSON documents and collections is needed, as CRUD is a minimum.
4. No dynamic indices, no triggers, no cursors - no bells... no whistles.
6. Data should still be organizable - _collections of documents_ seems fair.
7. Persistence between database boots is a must.
8. Some sort of simple authentication and authorization for new connections.

Now, with a clearer scope in mind, let's move onto terminology.

### Terminology
#### Item
A document is stored as _an Item_. The item will belong to a single collection and will store it's data as JSON.

#### Collection
Many Items are stored in _a Collection_. Access to Items must only happen through their Collection.

#### Language
Statements are constructed using JSON. Seems like a neat-fit and matches the data structure is stores.

#### Store
Holds references _to Collections_. Provides an interface fetching an manipulating Collections and Items.

#### Command
Executes a defined behaviour against _a store_ and returns a result. This can be a Write and Query command

## High-Level Overview of the Design
At a very high-level overview, the database implements a simple [Read-Eval-Print-Loop](https://en.wikipedia.org/wiki/Read%E2%80%93eval%E2%80%93print_loop) which accepts input from a database connection and attempts to parse and execute this input as a command. It does so in the following order:
1. Read input from the client (Read)
2. Parse into a command (Read)
3. Execute Command against internal Data Store (Eval)
4. Serialize the Result into a String (Eval)
5. Send the String back to the client (Print)
6. Wait for the next input from the client (Loop)

{{< gravizo "High-Level Overview" >}}
@startuml
partition "Read" {
  (*) --> "Read input"
  "Read input" --> "Parse Command from Input"
}

partition "Eval" {
  "Parse Command from Input" --> "Execute Command"
  "Execute Command" --> "Serialize the Result"
}

partition "Print" {
  "Serialize the Result" --> "Return the Serialized Result"
}

"Return the Serialized Result" --> "Loop"
"Loop" --> "Read input"
@enduml
{{< /gravizo >}}


## The _Core_ Package
The logic of creating, querying, and manipulation of Stores, Collections, and Items and their data, is hosted within the bounds of of the _core package_ of the application. It's primary concern is focused directily concealing this logic behind an Intention Revealing Interface and is completely agnostic to external concerns such as executing Commands or persisting itself between changes.

For example, when a command would like to add a new Collection to a Store, it would not do so directly such as:
```golang
store.Collections = append(store.Collections, core.Collection{...})
```

As this introduces a few problems. Firstly, it describes no real intention of it's action and future would-be-readers may not understand the importance of this action. Secondly, it puts the burden of building a new collection and adding that collection to the store onto the client.

The interface hides these complexity behind an interface:

```golang
collectionName := "SweetCollection"
store.CreateCollection(collectionName)
```
All interactions happen behind these Intention Revealing Interfaces to describe _what_ will happen and releaves the client from understand how it happens.

The components are quite simple, with each one being implemented as a struct. Stores know about their Collections, Collections know about their Items, and Items know about their data. 
The most atomic part of the _core package_ is the [Item](https://github.com/APiercey/RygelDB/blob/main/core/item.go). It's primary responsability is to control how it's Data is set and how the internal structure can be traversed. 

For example, a Command may know what sort of data it is looking for but does not have access to items directly without first going through a Store and it's Collections.

{{< gravizo "Core Package Component Relationship" >}}
@startuml
  [Store] -> [Collections] : holds references to
  [Collections] -> [Items] : holds references to
  [Items] -> [Data] : stores
@enduml
{{< /gravizo >}}

## Commands and Execution

## Tying it all Together
The main function of the application does a few things on boot-up:
1. Start a SocketServer
2. Define a ConnectionHandler
3. Create a new Store

The _SocketServer_ is used for both receiving input and returning serialized results and does so using a ConnectionHandler. When this ConnectionHandler starts, it kicks-off the REPL cycle and begins to wait for input.

Once input is received, it parses the input into a Command using a CommandParser and executing that Command against the Store.

{{< gravizo "Components and their Relationships" >}}
@startuml
package Store as StorePackage {
  [Store]
  [Collection] as Coll
  [Item] as Item
  
  Store ..> Coll : manages multiple
  Coll ..> Item : manages multiple
}

package Commands {
  interface Command as Comm
  [Command Parser] as CommParser
  
  Comm ..> Store : executes behaviour on
  CommParser ..> Comm : builds
}

package Main {
  [SocketServer] as SS
  [ConnectionHandler] as CH
  interface Conn 

  SS ..> CH : starts
  SS ..> Conn : builds
  CH ..> Conn : reads input using
  Conn ..> CH : sends result using
  CH ..> CommParser : parses input using
  CH ..> Comm : executes
}
@enduml
{{< /gravizo >}}

### Quick Note About Persistence
I did say I wanted to persist data between sessions - I also said I wanted things to be simple. Ultimately, I settled on a very simple approach: Commands notify the calling client (Main in the diagram above) if the store has changed. If it has, the Store will be persisted to the disk in the form of a database dump.

On boot-up, the main function looks for a database dump and attempts to unmarshal the data into a proper Store object.

It's not exactly elegant but fits the purpose until more strenuous needs arise.

## Commands
The lingual needs of the database or quite small. With only a few commands, we can achieve what we need.

#### Defining Collections
```ruby
DEFINE COLLECTION collection_name
```
will create a new collection where document items may be stored.

#### Storing Data
```ruby
STORE INTO collection_name key {"data": "structure of document"}
```
will store a document item.

#### Lookup of direct data
```ruby
LOOKUP key IN collection_name
```
retrieves a document by key

#### Querying data
```ruby
FETCH [all | 1, ...n] FROM collection_name [WHERE path.of.document.properties IS value AND ...n]
```
queries data using 0 or many WHERE clauses and enforces either _all_ or a limit.

Given the following data:
```ruby
DEFINE COLLECTION fruits
STORE INTO fruits apple {"key":"apple","color":"red"}
STORE INTO fruits orange {"key":"orange","color":"orange"}
```

Querying for a single document would look like:
```ruby
FETCH 1 FROM fruits
```
> [{"color":"orange","key":"orange"}]

Querying for all documents that meet a criteria:
```ruby
FETCH all FROM fruits WHERE color IS red
```
> [{"color":"red","key":"apple"}]

It's possible to query based on deep properties and multiple WHERE clauses:
```ruby
STORE INTO fruits orange {"key":"dragonfruit","color":"red","properties":{"spikes":"many","internal_color":"white"}}
FETCH all FROM fruits WHERE color IS red AND properties.internal_color IS white
```
> [{"color":"red","key":"dragonfruit","properties":{"internal_color":"white","spikes":"many"}}]

#### Remove data
```ruby
REMOVE [COLLECTION | ITEM] collection_name [key]
```
removes either a collection or a document item in a collection. Key is mandatory when removing a document item.

## Conclusion
The database is simple and served as a wonderful tool for self-improvement. In the end, my colleague was probably right - it was easy enough, if you don't try to build all the "extras" you love from the database you use in your professional life.

### Future Ideas
#### Add tests
Why didn't I add any? I found testing in Golang to be very straight-forward without many gotchas. Tests existed at the start but I removed them after they stopped providing value.

#### Append To File for Persistence
It would be far more efficient to store the results of store-altering Commands to disk rather than dumping the entire file. The Store would require replaying through the append data before serving Commands.

This would lengthen the boot-up time but incremental snapshots would make a considerable difference, as well.

#### Read-Replicas
If only for the sake of learning.

#### Implement a Proper Command-Oriented Language
The parse is quite naive. It is a bit clumsy in places and doesn't really provide flexibility needed for a proper NoSql database.

Implementing a proper Parser and Tokenzier would allow for complex queries and data manipulation.

#### More Query Support
In general, the commands provided are the basic minimum for CRUD operations but there is much left to be desired.

For instances, when multiple WHERE conditions are provided it currently only supports exact match through the `is` keyword. Future improvements could be:
- Partial match or LIKE match
- `is not` for when it should not match
- When a nested structure does not confirm or when nested value does not exist

#### Creating and Removing Indices
Currently only a single "index" exist - which is querying by the `key` and only works for LOOKUP statements. Support for adding indices would greatly improve it's design and more it more flexible.

Depending on how the "Command-Oriented Language" would mature, it may be beneficial to continue to use indices only on LOOKUP statements rather than having FETCH operate using indices as well.
