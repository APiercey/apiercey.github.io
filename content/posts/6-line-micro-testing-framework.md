---
title: 6 Line Micro Testing Framework
date: 2023-03-20
description: A portable and dependency free micro testing framework useful in remote situations
image: images/microframework/pollux-and-castor.jpg
imageCredit:
  url: https://www.facebook.com/DeepSkyColors
  text: Pollux and Castor by Rogelio Bernal Andreo
draft: false
disqusIdentifier: "njliusf7t"
---

Normally, I try to write tests for every project I participate in, even personal projects that never see the light of day! Yet, every once in a while, I find myself working in an environment where adding new dependencies isn't so straightforward or tools like RSpec are a bit too bulky. In such cases, I quickly produce a few functions that allow me to execute automated tests. 

In Ruby, it's quite compact and pleasant. Here is an example, at a whopping 6 lines:

```ruby 
module MT
  def self.assert(desc, left, operator, right = nil) = puts (if msgs = self.send(operator, desc, left, right) then failure(msgs) else success(desc) end)
  def self.test(desc, &block) ; puts desc ; yield ; puts "\n" end
  def self.success(msg) = "  \e[32m#{msg}\e[0m"
  def self.failure(msgs) = "  \e[31m#{msgs.join("\n    ")}\e[0m"
end
```

I _sliiightly_ lied, as it's not very useful on its own. It indeed works as a micro "_framework_" so we need to add our own assertions. We can open the module up and define our own.

An assertion is defined as a method that accepts three arguments: a description, a left comparison, and a right comparison. Its return value should be `nil` on success and a list of failure messages on failure.

For example:

```ruby
module MT
  def self.equals(desc, left, right)
    return nil if left == right
    ["#{desc} failed.", "Expected: #{right}", "Received: #{left}"]
  end
end
```

This can be compacted into a single elegant line with ruby 3! We'll do that and add a few more:

```ruby
module MT
  def self.equals(desc, left, right) = (["#{desc} failed.", "Expected: #{right}", "Received: #{left}"] unless left == right)
  def self.doesnt_equal(desc, left, right) = (["#{desc} failed.", "Expected: #{left} and #{right} not to be the same"] if equals(desc, left, right))
  def self.contains(desc, left, right) = (["#{desc} failed.", "Expected: #{left} to contain #{right}", "Received: #{left}"] unless left.include?(right))
  def self.is_a(desc, left, right) = (["#{desc} failed.", "Expected: #{left} is a #{right}", "Received: #{left.class}"] unless left.is_a?(right))
end
```

# Test Run
```ruby
#  basic_comparisons.rb
MT.test "Basic comparisons" do
  MT.assert("Comparing values", 1, :equals, 1)
  MT.assert("Array contents", [1, 2, 3], :contains, 3)
  MT.assert("Class types", "Hello world", :is_a, String)
  MT.assert("true is truthy", true, :is_truthy)
  MT.assert("objects are truthy", "Technically an object", :is_truthy)
  MT.assert("false is falsey", false, :is_falsey)
  MT.assert("nil is falsey", false, :is_falsey)
  MT.assert("nil is nil", nil, :is_nil)
  MT.assert("Strings can be matched", "Foo bar", :matches, /Foo/)
end



class Dog < Animal
  def bark
    "Woof! Woof!"
  end
end

MT.test "Dog" do
  dog = Dog.new

  MT.assert("it is an Animal", dog, :is_a, Animal)
  MT.assert("it woofs when it barks", dog.bark, :equals, "Woof! Woof!")
end
```

Executing them yields a nice green run with our assertions categorized under our tests:
![MT Execution with Successes](/images/microframework/mt-successes.png)

Flipping some values shows failure messages:
![MT Execution with Failures](/images/microframework/mt-failures.png)

# Conclusion
And that's it! A dependency free, simple micro testing framework that can be dropped into any project. Particularly useful when installing dependencies isn't practical.

A full copy of the framework and assertions can be found in [this gist](https://gist.github.com/APiercey/70ca3a5c61569d534edc41c85c546cd8).

