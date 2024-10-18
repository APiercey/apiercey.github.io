---
title: "My Teacher"
date: 2024-10-16
description: Many years ago, my teacher taught my class how to write software - real software. With all the complexities of working together.
image: images/matsumoto.jpg
showTOC: false
draft: false
useComments: true
imageCredit:
  url: https://instagram.com/moabitdottir
  text: Matsumoto City by Moabitdottir
showTOC: false
draft: false
useComments: true
utterenceIssueNumber: 7
keywords:
  - teacher
  - learning to program
  - programming
  - integration
  - git
  - delivery
  - shipping code

---

_A while back I had shared this story as a message in Slack with some colleagues. I was encouraged to publish it but never had a chance to do so until now. I hope you enjoy it :)._

# My Teacher

I'm currently reading this article by Martin Fowler on [Continuous Integration](https://martinfowler.com/articles/continuousIntegration.html) (which I would always recommend anyone to read)!

His opening story about the dangers of integrating parts of software reminded me of an experience I once had. It's an interesting story I think of sometimes, so I'd like to share it all with you.

Many years ago, when I _really_ started studying programming, I had a programming class with a teacher who had already taught us how to program. But now, she was going to teach us how to _write software_. Interesting difference, no?! Often we think of programming as this "fun task" we sort of do by ourselves - which is mostly true - but programming is actually a very small aspect of _writing software._ Writing software is both a large collaborative problem that is distributed by nature and a "people managing" problem.

Back when I started, `git` wasn't "really" a thing yet. [In fact,](https://softwareengineering.stackexchange.com/questions/136079/are-there-any-statistics-that-show-the-popularity-of-git-versus-svn) `git` [only really started to establish market dominance in about 2013](https://softwareengineering.stackexchange.com/questions/136079/are-there-any-statistics-that-show-the-popularity-of-git-versus-svn)! And it was hardly used at all in the "corporate" world. We used other things, sure, but they were **shit**. Real shit! A lot of teams of programmers would actually write a feature for a program on their own computer and then _ship the code by email_ to the group via a mailing list!

Each programmer, in turn, would have the (dis)pleasure of **integrating** that piece of code into their own local versions. It was peak development for its time, ironically.

As you could imagine, there was always an insane amount of issues that resulted in working this way. With many engineers claiming it _"Works on my machine. Sounds like a **you** problem!"_ (with some of them finding out it did **not** in fact work on their machine...). This often had the effect of programmers sometimes being "booked out" of their calendar for "integration" meetings, where engineers would come together to integrate shipped code into each of their local "versions".

What a dreadful way to work! The advent of version control (which was, again, shit at the time) and `git` changed a lot of that. But remember, people weren't _really_ using true version control.

Most version control at its heart was just terribly organized and poorly named directories like "Jan 3rd version", "Jan 4th version", "Jan 4th version final", "Jan 4th version final REAL"... you get the point. This would be shared over FTP, email, NAS, or whatever the IT department prescribed you with. God help you if you integrated with the incorrect "version"!

So, how had our teacher taught us how to write software at the time?

## The Project

She used a project to teach us some very interesting principles that we see even to this day! At the beginning, we all got together to discuss the challenge. The project was a collaborative exercise of the entire class (I think about 25 students?) working together to write a single program. We had 3 months to accomplish this task.

While looking for a solution, most of the problems we could see had nothing to do with the complexity of the project but actually the integration of different working parts. The program was far too large for a single person to write and there were way too many working parts for us to continually run into "integration challenges".

So what were the things we learned that allowed us to accomplish this?

- Rely on abstractions, not concrete classes. Meaning, we agree on behaviour and not concrete code.
- Interfaces are incredibly important! We don't need to care "what is going on behind the curtain". We only need to agree on inputs and outputs.
- Decouple **everything.** There is no central command-and-control. The problem we learned was that there would be a crazy amount of churn. We would be stuck forever in integration issues and changing logic.

I could not put the above into those words then but that is what we did, in fact, learn. Once our solution was laid out, we had a UML(ish) schematic with a solution of different parts of the program that fit together to implement the solution.

We then broke into different "groups" (teams) responsible for different parts of the software  with some groups even adopting some fun names. Each part of the software was a module and each module only depended on other modules through their interface (which were just simple Java interfaces, actually). Internally to each group, each person was responsible for a feature in that module, which always resulted in them implementing that feature as a Class (_cough cough_ [Conways Law](https://en.wikipedia.org/wiki/Conway%27s_law)) and other group members relying on the abstraction of each others Classes.

Each group would try their best to integrate quickly amongst themselves. However, our teacher had a rule!! Every group must integrate with each other group's work **at least once a week** (yikes)! The aim of this rule, was to prevent group's code from drifting "too far" from each other and making integration impossible for a school project.

So how did we solve this? We decided that a single person in the class would be responsible for coordinating integrations. Instead of shipping updates to a mailing list we should ship these updates to this single person. They would **integrate the code, test it, and then send out a full updated and working copy** to the rest of the class!

Doesn't this sound familiar?!

<img class="pull-left" src="/images/john_cena_shocked.gif" alt="Description of image" width="480" height="418">

It's basically CI/CD, QA, and Integration Manager as a defined role in the team. This role, still exists to a large degree in modern software development (even though some of these technical tasks are more or less automated).

As it turns out, this was a full time (in scope of the class) job! This person needed to be technical but also have great soft skills to coordinate discussions amongst different teams. They became the project manager, coordinating releases, resolving technical discussions, providing QA, etc.

Sometimes the person in this role would change, as the individual wanted to actually help their group to write some code. But naturally, some people took to this role with enjoyment. Coincidentally, some of them (many years later) went on to be great managers and QA engineers. They remained in this role for a larger amount of time than others. But the key to its success was that it was a **rotating role**. In my opinion, this is the Scrum Master role - which should also be a rotating role.

So what did this look like in the end and what was the result?

- We had about 6 groups.
- Groups worked amongst themselves. We shipped a small working version of individual modules per week via email.
- The "integration member" would integrate previous weeks version and ship it by end of the week via email.
- Groups would integrate the new working version and communicate any breaks/bugs to the "integration member".
- The "integration member" would coordinate fixes with the appropriate team.
- Rinse and repeat.

We valued early integration and did it often. We valued smaller programs that worked together, rather than a single "monolith". We valued a single stream of work rather than many streams of work. We valued agreements of boundaries instead of implementation of boundaries. We valued early escalation of concerns, rather than finding out much later.

Amongst many more, I'm sure!

Towards the end, sometimes groups work were feature complete. So members joined other teams. But in the end, we had a wonderful piece of working software! It was (mostly) bug free, worked well, and met all the criteria of the project. We all passed with an **A+**, the highest mark. I'm still in contact with these folks many years later.

Thinking back, I really miss my teacher. She was truly incredible. This way of working was well beyond our understanding back then nor did we have any experience in the industry. There was **no way** we would have come to this solution or level of understanding of tackling complex problems without her but the way she guided us, made us believe that _we came to this understanding by ourselves._ It instilled a level of confidence that made us feel an incredible sense of pride in ourselves, which was so critical in those formative years.

And that's a wrap to my story!
