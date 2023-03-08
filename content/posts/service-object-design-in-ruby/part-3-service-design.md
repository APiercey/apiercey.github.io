---
title: "SODR Part 3: Service Design"
date: 2022-10-03
description: TODO
image: images/space-cerqueira.jpg
showTOC: true
draft: false
---

Design Characteristics of all Services
1. Statelessness and Immutability
- What does immutability mean
- What does statelessness mean
  - State is not held in memory
  - What about cache?
    - Caching requests is fine
3. Prefer Asynchrnous communication over Synchronous
4. Throw errors, don't return them. AKA Fail Fast.

Application Services
1. Responsibilities
  - Part of the Application Layer
  - The entrpooint or "proxy" for the business logic.
  - Technology agnostic
  - Coordinates business logic (does not implement business logic, business logic is part of the domain layer) 
3. Naming of Classes and Methods
4. Method Parameters
  - ID of object the action is for.
  - additional attributes for write/update statements
5. Return Value
  - When not splitting Reads and Writes
    - Can be tricky. 
      - The needs of READING an object tends to grow in larger _technical_ complexity rather than _domain_ complexity.
      - The needs of WRITING/UPDATING an objects tend to grow in _domain_ complexity rather than technical complexity.
      - These two sets of needs _really_ like to get in the way with each other.
        - For example, if returning an object that exposes an interface for querying for more data, make sure 
      - Return entire object
      - ^^^ Code example.
  - When splitting Reads and Writes
    - Returning ID value for creating new objects.
    - true for updates/deletes
    - Offers the highest degree of flexibility. APIs generally

Domain Services
1. Responsibilities
1. Naming of Classes and Methods
2. Method Parameters
3. Return Value

Infrastructure Services
1. Responsibilities
1. Naming of Classes and Methods
2. Method Parameters
3. Return Value

Return Values
- Boolean returns
- Value Object Returns
- Meaningful returns (what does DDD book call it?)
- Application Services return either ID, boolean/failure
1. Application Services
2. Domain Services
3. Infrastructure Services
