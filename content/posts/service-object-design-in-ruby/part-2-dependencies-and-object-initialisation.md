---
title: "SODR Part 2: Dependencies and Object Initialisation"
date: 2022-10-03
description: TODO
image: images/space-cerqueira.jpg
showTOC: true
draft: false
---

## The First Pillar of Good Service Design 
The first pillar of good Service Design is how a service is initialised, in particular with it’s dependencies. Ruby is quite a flexible language that allows for many different styles, so let’s explore them with their Pros and Cons.

We will be using an example Application where creditors can provide donations to debtors. It is an Application part of a greater system where other components are managed.

## Style One: Initialisation Dependencies on Init
One of the more common styles used. Objects will initialise their own dependencies when the object itself is being initialised.

### Code Example

```ruby
class DonationApplicationService
  def initialize
    @user_repo = UserRepo.new
    @donation_repo = DonationRepo.new
    @donate_amount_service = DonateAmountService.new
    # ...
    # even more dependencies for other requirements!
  end

  def donate_amount(amount, creditor_id, debtor_id)
    creditor = @user_repo.find_by!(creditor_id)
    donation = @donation_repo.build(amount, creditor.uid, debtor.uid)

    if @donate_amount_service.call(donation)
      @donation_repo.store(donation)
    else
      fail CannotDonateAmount
    end
  end
end
```

In this example, our Application Service initialises at least three more dependencies: a UserRepo, DonationRepo, and a DonateAmountService. Each one of these will have it’s own dependencies, which are initialised at the time when they are initialised. 

The DonationRepo initialises it’s own DatabaseConnection object:

```ruby
class DonationRepo
  def initialize
    @write_db_connection = DBConnectionBuilder.build
  end

  def build(amount, creditor_id, debtor_id)
    Donation.new(
      amount: amount,
      creditor_id: creditor_id,
      debtor_id: debtor_id,
      donation_date: DateTime.now
    )
  end

  def store(donation)
    donation_data = donation.to_h
    @write_db_connection[:donations].insert_or_update!(donation_data)
  end
end
```

The UserRepo initialises it’s own HTTPClient object:
```ruby
class UserRepo
  def initialize
    @user_auth_client = Http::Client.new(ENV["USER_AUTH_SERVICE_URL"])
  end

  def find_by!(uid)
    @user_auth_client.get!("/users/#{uid}")
  end
end
```

Our DonationApplicationService object would then be used at the edges of our application, usually in a HTTP Server or Background Worker. Here are some examples of how they can be initialized:

With Grape:
```ruby
class API < Grape::API
  # Application Services can be included here
  helpers do
    def donation_application_service
      @donation_application_service ||= DonationApplicationService.new
    end
  end

  post '/donations' do
    # ...
    # the service can then be invoked within the API methods
    donation_application_service.donate_amount(...)
  end
end
```

With Sinatra:
```ruby
def donation_application_service
  @donation_application_service ||= DonationApplicationService.new
end

post '/donations' do
  # ...
  # the service can then be invoked using the method helper
  donation_application_service.donate_amount(...)
end
```

With Sidekiq:
```ruby
class Worker
  include Sidekiq::Job
  
  def donation_application_service
    DependencyTree.donation_application_service
  end
end

class DonationRequestedWorker < Worker
  def perform(*args)
    donation_application_service.donate_amount(...)
  end
end
```

### Testing
The fact that we are breaking Dependency Inversion increases the complexity in how we test, when we want to test in isolation.

For each dependency, we must intercept the send signal to the dependency’s `new` method and interject our own. Then, we must mock our expected behaviour.

A test to assert that a donation is correctly stored could look like this:

```ruby
RSpec.describe "ApplicationDonationService" do
  let(:donation_application_service) { ApplicationDonationService.new }
  let(:mocked_donation_repo) { instance_double(DonationRepo) }
  let(:mocked_user_repo) { instance_double(UserRepo) }
  let(:mocked_donate_amount_service) { instance_double(DonateAmountService) }

  describe "#donate_amount" do
    subject { donation_application_service.donate_amount(amount, creditor_id, debtor_id) }

    let(:donation) { Donation.new } 
    let(:user) { User.new }

    let(:creditor_id) { 1 }
    let(:debtor_id) { 2 }
    let(:amount) { 1000 }

    before do
      allow(UserRepo).to receive(:new).and_return(mocked_user_repo)
      allow(mocked_user_repo).to receive(:find_by!).with(creditor_id).and_return(user)

      allow(DonationRepo).to receive(:new).and_return(mocked_donation_repo)
      allow(mocked_donation_repo).to receive(:build).with(donation).and_return(donation)
      allow(mocked_donation_repo).to receive(:store).with(donation).and_return(donation)

      allow(DonateAmountService).to receive(:new).and_return(mocked_donate_amount_service)
      allow(mocked_donate_amount_service).to receive(:call).with(donation).and_return(true)
    end

    it “stores the donation” do
      expect(mocked_donation_repo).to receive(:store).with(donation)

      subject
    end
  end
end
```

There are some serious issues with this test that this style introduces:
- First, it takes nine lines of code to setup a single test! Considering this is the “happy case” where everything goes right, we would still need to cover what happens when thigns go wrong.
- Second, we need to understand the complete internals of the `donate_amount` method to test it. Unecessray implementation logic is leaking into our tests, making them brittle. For example, do we really care that the UserRepo uses `find_by!? What if we want to change it to `find_using!`. Does the test really need to fail if the behaviour of the method is still the same?
- Third, we have no choice but to assume what the return value of our dependencies are. In the test we assume that the `call` method of `DonateAmountService` returns `true` but it could be returning an entirely different object. It may even be returning an object suggesting the operation failed!

Alternatives
- Do not mock and let the real dependencies be used. May be acceptable for dependencies within your control, such as the Database, but not acceptable for remote calls.
- Use a Fake (link to Martin Fowler), instead of a mock. You will still be required to intercept the `new` method calls and return your Fakes.


### Pros and Cons
Pros:

This style keeps dependencies hidden from client code. The initialiser does not need to know about the dependencies of it’s own dependencies. 

Additionally, an object cannot be successfully initialised unless all of it’s dependencies have been successfully initialised as well! Meaning, if a an object has been initial, it is safe to use. This prevents faulty dependencies from being initialised at a later point in time and breaking in the middle of program execution.

Lastly, there is a small bonus for the developer: explicit dependencies make it easier for code editors to use features like Code Jumping and Code Completion (https://langserver.org/).

Cons:

The most damning thing about this style is that if it's  locks it’s dependencies into a single concrete class. If the dependency is designed using Inheritance or Polymorphism, changing it’s dependencies requires changing the implementation of the class itself! 

This breaks a number SOLID principles:
- Single-Reposnibilty: If we need to change a class’s dependency to yield different behaviour in the responsibility of those dependency, then our class has changed because of a reason outside of it’s responsibility.
- Liskov Substitution: We cannot rely on a base class behaviour but rather whatever the specific behaviour of what our dependency is.
- Dependency Inversion Principle: We do not rely upon any sort of abstraction.

Testing this code is cumbersome and can lead to brittle tests that end up not testing real behaviour.

### Conclusion
Recommended for rather simple code base. It has the benefit of being simple and if no other abstractions are required for your dependencies, the added benefits might be negligible.

1 to 5
Extendibility: 2, changing the depencies may be a simple code change
Reliability: 3, bad dependency initialization the depencies. Tests can lead to incorrect results.
Testibility: 2, testing is cumbersome and can lead to incorrect results. In my own experience, such tests produce false-positives occasionally (it just hasn’t bit us in the ass _yet_!)

## Style Two: Inline Initialization 
It’s possible to initialize depencies only once they are used. More often then not, memozation techniques (TODO: Link to memozation) are used to prevent unecessary re-initialization of services. This style is quite similar to Initialisation Dependencies on Init.

### Code Example

```ruby
class DonationApplicationService
  def donate_amount(amount, creditor_id, debtor_id)
    creditor = @user_repo.find_by!(creditor_id)
    donation = @donation_repo.build(amount, creditor.uid, debtor.uid)

    if @donate_amount_service.call(donation)
      @donation_repo.store(donation)
    else
      fail CannotDonateAmount
    end
  end

  # ...

  private

  def user_repo
    @user_repo ||= UserRepo.new
  end

  def donation_repo
    @donation_repo ||= DonationRepo.new
  end

  def donate_amount_service
    @donate_amount_service ||= DonateAmountService.new
  end

  # ...
  # even more dependencies for other requirements!
end
```

Just like the style Initialisation Dependencies on Init, this style requires the object to still responsible for initializating it’s own dependencies.

### Testing
Testing this code is the same as Initialisation Dependencies on Init with the added complexity that dependencies are still being setup/initialized in the middle of our test runs! Yikes!

Debugging issues that arise from failed test runs ussually requires a debugger. If we suspect that failures could be coming from faulty dependencies, we would have to add break statements (e.g. binding.pry) and inspect our dependencies by hand to understand if they are bein intialized corrrectly.

```ruby
  def donate_amount(amount, creditor_id, debtor_id)
    # Break point to start inspecting our method
    binding.pry
    
    creditor = user_repo.find_by!(creditor_id)
    donation = donation_repo.build(amount, creditor.uid, debtor.uid)

    if donate_amount_service.call(donation)
      donation_repo.store(donation)
    else
      fail CannotDonateAmount
    end
  end
```

### Pros and Cons

Pros:
This style keeps dependencies hidden from client code. The initialiser does not need to know about the dependencies of it’s own dependencies. 

There is a small bonus for the developer: explicit dependencies make it easier for code editors to use features like Code Jumping and Code Completion (https://langserver.org/).

Cons:
This style suffers the same draw backs as Initialisation Dependencies on Init. However, it comes with one additional draw back that because dependencies are not initialized when the object is initialized, a faulty dependency may be initialized in the middle of execution.

Consider the `donate_amount` method on DonationApplicationService. What should happen if `DonateAmountService` fails to initialize, which would be the final object to initialize?

Clients would be required to distinguish between _business logic_ failure and a _programtic_ failure even after all objects have been setup seemingly success! Without using this style, progamatic failures would occur before business logic has even been initiated.

If such failures occur, what type of error response should client return to the user using the software?

Additionally, understanding this code becomes more complex. Attempting to follow the execution of code is literred with object complex object initialization and doubts of, “Are we _sure_ this dependency is working?”.

### Conclusion
This style should be avoided at all costs! It gives no discernable benefits to the code base or the developers writing the code! It decreases reliability by introducing more points of failure.

1 to 5
Extendibility: 1, changing the depencies almost always results in a change in behaviour.
Reliability: 2, more points of failure are introduced. 
Testibility: 1, testing is cumbersome and can lead to incorrect results. Additionally, failures within test runs becomes harder to debug.

## Style Three: Dependency Injection
Often applications have more than one implementation of their dependencies, whether the programmer realises this or not. Consider how we would test Style One, for example. We mock some of our dependencies before define what inputs the mock accepts and the result it should return, we have effectivly created a new implementation that exists only within our test.

Dependency Injection allows these implementations to come to the forground of the codebase and be more explicit. We will take a look at tricks to make managing ourmultiple dependencies easier and safer.

### Example

#### Dependency Injection

Firstly, the problem with mocking our dependencies by intercepting Ruby's receive and send signals just provides noise to our tests. At worse, it ties the test to the implementation details of the Service object's dependencies depending on _how_ these dependencies are mocked. Let's take a look at this first.

When a class is instantiated, it's dependencies are provided as arguments to the class constructor.

Here are our new Class initializers:

```ruby
class DonationApplicationService
  def initialize(user_repo, donation_repo, donate_amount_service)
    @user_repo = user_repo
    @donation_repo = donation_repo
    @donate_amount_service = donate_amount_service
  end
  # ...
end

class DonationRepo
  def initialize(write_db_connection)
    @write_db_connection = write_db_connection
  end
  # ...
end

class UserRepo
  def initialize(user_auth_client)
    @user_auth_client = user_auth_client
  end
  # ...
end

class DonateAmountService
  # no dependencies
end

```

The benefit is yielded immediatly. We remove the responsibility of constructing dependencies from the class implementation. With this, we meet the requirements of D in SOLID (Dependency Inversion). Any failure to initialize a would-be dependency will happen before the Service object has event started to be instantiated, giving us (the developer) even quicker feedback that something is broken.


Finally, let's initialize a `DonationApplicationService` object and it's dependencies:

```ruby
# Initializing objects and their dependencies
user_auth_client = Http::Client.new(ENV["USER_AUTH_SERVICE_URL"])
user_repo = UserRepo.new(user_auth_client)

db_connection = DBConnectionBuilder.build
donation_repo = DonationRepo.new(db_connection)

donate_amount_service = DonateAmountService.new

donation_application_service = DonationApplicationService.new(
  user_repo,
  donation_repo,
  donate_amount_service
)
```

Our `DonationApplicationService` object is ready to be used! we've solved the problem of initializing our dependencies in the objects they are used in, however, now any client code that needs to use our object also needs to understand how to construct it! Consider how we would do this using Grape:

```ruby
class API < Grape::API
  # Application Services can be included here
  helpers do
    def donation_application_service
      @donation_application_service ||= do
        user_auth_client = Http::Client.new(ENV["USER_AUTH_SERVICE_URL"])
        user_repo = UserRepo.new(user_auth_client)

        db_connection = DBConnectionBuilder.build
        donation_repo = DonationRepo.new(db_connection)

        donate_amount_service = DonateAmountService.new

        donation_application_service = DonationApplicationService.new(
          user_repo,
          donation_repo,
          donate_amount_service
        )
      end
    end
  end

  post '/donations' do
    # ...
    # the service can then be invoked within the API methods
    donation_application_service.donate_amount(...)
  end
end
```

Honestly, not really that alluring, is it? One way of solving this issue is to use a Dependency Tree.

#### Dependency Trees

Sometimes called AppTree or Dependency Graph, a Dependency Tree is a component that has the responsibility of constructing objects specifically used as dependencies and provide them when requested.

Some tools provide some really fancy Dependency Tree components (I would even argue that they are _frameworks_) such as [Angular's Injectables](https://angular.io/guide/dependency-injection) or [Mavens Dependency Tree Plugin](https://maven.apache.org/plugins/maven-dependency-plugin/index.html) but there is a much simpler approach if we write implement one our selves.

```ruby
module DependencyTree
  class << self
    def user_auth_client
      @user_auth_client ||= Http::Client.new(ENV["USER_AUTH_SERVICE_URL"])
    end

    def write_db_connection
      @db_connection ||= DBConnectionBuilder.build
    end

    def user_repo
      @user_repo ||= UserRepo.new(user_auth_client)
    end

    def donation_repo
      @donation_repo ||= DonationRepo.new(write_db_connection)
    end

    def donate_amount_service
      @donate_amount_service ||= DonateAmountService.new
    end

    def donation_application_service
      @donation_application_service ||= DonationApplicationService.new(
        user_repo,
        donation_repo,
        donate_amount_service,
        donation_reporting_service
      )
    end
  end
end
```

There are some benefits to this approach. Firstly, the use of memozation allows object reuse which can be quite important when building objects such as `DBConnection` which may open up new connections to the database. Secondly, by hiding the initialization behind methods, we can initialize all the dependencies of a given object _and_ the object we want with a single method call. Lastly, the use of `class << self ... end` declares these methods as part of the `DependencyTree`'s' singleton class.

We can use our service object through our DependencyTree like so:

With Grape
```ruby
class API < Grape::API
  # Application Services can be included here
  helpers do
    def donation_application_service
      DependencyTree.donation_application_service
    end
  end

  post '/donations' do
    # ...
    # the service can then be invoked within the API methods
    donation_application_service.donate_amount(...)
  end
end

```

And one final example, using Sidekiq
```ruby
class Worker
  include Sidekiq::Job
  
  def donation_application_service
    DependencyTree.donation_application_service
  end
end

class DonationRequestedWorker < Worker
  def perform(*args)
    donation_application_service.donate_amount(...)
  end
end
```

### Testing
Replace our mocks with Fakes. Fakes are great for things that have side effects. Use Fakes for things within our application and Mocks for things outside our application. We consider the datbase to be outside the application.

```ruby
RSpec.describe "ApplicationDonationService" do
  let(:donation_application_service) do
    ApplicationDonationService.new(user_repo, donation_repo, mocked_donate_amount_service)
  end
  
  let(:fake_donation_repo) { FakeDonationRepo.new }
  let(:fake_user_repo) { FakeUserRepo.new }
  let(:mocked_donate_amount_service) { double(DonateAmountService, call: true) }

  describe "#donate_amount" do
    subject { donation_application_service.donate_amount(1000, 1, 2) }

    it "stores the donation" do
      subject
      
      expect { fake_donation_repo.all.count }.to_change.by(1)
    end
  end
end
```

With this implementation, we test the side affects of our service rather than the direct implementation. We don't really care _how_ these dependencies are used, just the effects it has on them (and therfor our system).

A large benefit we gain is a much simpler test that is consice. It requires minimum setup and the Fakes are reusable across many tests, which is great because if there is a change in behaviour, we will see if this change would impact any of our services negativly.

This is particularly interesting as well implemented fakes can serve both our Unit tests and a stand-in replacement for our class when used in UAT environments. This is great for eliminating high-cost API calls or flaky dependencies in these environments.

### Pros and Cons

Pros:
- Initializing Service dependencies happens in single class named DependencyTree and it is the Single Responsibility of that class.
- Dependencies are injected into Service Classes, freeing themselves of those classes responsibilites and changes in behaviour.
- Different implementation can easily be used as we depend on abstractions rather than concrete implementations.
- Testing is far easier as implementing new test cases requires less setup and focuses on the Service undertest, rather than setting up the dependencies.

Cons:
- More complex than previous styles.
- Additional classes are required for testing, which can be seen as an overhead.


### Conclusion
Using Dependency Injection allows fo much higher flexibility and granularity for testing. We are not forced to use clever tricks to use different implementations when we put our classes under test.

Extendibility: 4, this style allows for the most extendability our of what is covered today. However, we are left with building the dependency tree ourselves.

Reliability: 5, five is given because objects can be tested in true isolation. Failures around object initialization happen outside of classes.

Testibility: 4, this style provides the easiest form of testability. Classes are setup from the outside in for both unit test and running code.
See code examples in ~/PersonalProjects/dependency_injection_ruby

## Recommendation and Final Thoughts
My recommendation for most applications is Style Three. It provides the best flexibility for testing and keeps objects small with fewer responsibilities. If using Fakes feels too much of a leap, the style still easy testing with mocks without the yucky signal interception.

Style One is a nice compromise for existing code bases, especially ones that already have a mix between Styles one and two, and perhaps ones which aren't listed here. Refactoring existing service objects to utilise Style One in these codebases will help cut down on reader misdirection.

Finally, there exists more styles than the ones described here as Ruby allows for a high degree of options. Nevertheless, I feel what is written down here includes the primary characteristics of almost all styles. For example, one option is to include build dependencies in an object similar to that of Dependency Tree and inherite helper methods that expose a service dependencies:

```ruby
module DependencyTree
  class << self
    def user_auth_client
      @user_auth_client ||= Http::Client.new(ENV["USER_AUTH_SERVICE_URL"])
    end

    def write_db_connection
      @db_connection ||= DBConnectionBuilder.build
    end

    def user_repo
      @user_repo ||= UserRepo.new(user_auth_client)
    end

    def donation_repo
      @donation_repo ||= DonationRepo.new(write_db_connection)
    end

    def donate_amount_service
      @donate_amount_service ||= DonateAmountService.new
    end
  end
end

class AbstractApplicationService
  def user_repo
    DependencyTree.user_repo
  end

  def donation_repo
    DependencyTree.donation_repo
  end

  def donate_amount_service
    DependencyTree.donate_amount_service
  end
end

class DonationApplicationService < AbstractApplicationService
  def initializse
    # Empty initialize left for clarity
  end
end

donation_application_service = DonationApplicationService.new
```

Such styles do a great job at hiding how objects are constructed, however they are either a mix or reimplementation of the Styles described.

Even more important, this particular example has two critical flaws.

Firstly, we allow any and every class that uses this style to add dependencies at the developers whim. Adding a dependency should be a very intentional and explicit act. The moment we need we need to understand which classes are using which dependencies, we have no choice but to inspect the entire code base. Refactoring and deprecating classes becomes a nightmare.

Secondly, we would be creating a new database connection for every _application service_ instantiated in our application! This would require us to seperate initializating dependencies depending on their type, into distinct parts of our application. This ends up hiding a lot of important details when it comes to tweaking your application for perforamance.
