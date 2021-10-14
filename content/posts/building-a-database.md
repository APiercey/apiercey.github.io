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
In the beginning, my imagination ran wild and before long I dreamt of a distributed datastore with read-replica support, all supported by a series of stored events, and all the bells and whistles that comes with [a new toy](https://news.ycombinator.com/item?id=21897132). But alas, self-guilt got the better of me and to prevent ironic friendly-fire, I drafted a scope:

- Store simple types, JSON documents is fine.
- Querying is needed - but nothing complex outside of a few "and" statements.
- No dynamic indices, no triggers, no cursors - no bells... no whistles.
- Data should still be organizable - collections of documents is fair.
- CRUD is minimum.
- Persistence between database starts is a must.

A sort of **MVP** of what you could expect of a database without optimizations.

Now, with a clearer scope in mind, let's draft concrete terminology.

### Terminology
#### Item
A document is stored as _an Item_.

#### Collection
Many Items are stored in _a Collection_.

#### Language
Interacting with the database uses _Command-Oriented_ language. I am feeling inspired by [Redis](https://redis.io/commands).

#### Store
Holds references _to Collections_. Provides an interface fetching an manipulating Collections and Items.

#### Command
Executes a defined behaviour against _a store_ and returns a result.

## Basic Design
The database implements as simple [Read-Eval-Print-Loop](https://en.wikipedia.org/wiki/Read%E2%80%93eval%E2%80%93print_loop) and executes Commands issued against the database in the following order:
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
