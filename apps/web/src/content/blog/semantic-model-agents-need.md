---
title: "A Semantic Model is All Your Agents Need"
description: "In my previous post I named the trap: stay on a pile of SaaS and accept Semantic Bankruptcy, or vibe-code my way out into Structural Bankruptcy. Either road ends at a Frankenstack, and I closed with the only honest thing I had: there has to be a better, saner solution."
pubDate: "2026-06-04"
heroImage: "~/assets/blog/semantic-map.png"
tags: ["saassprawl", "opinion"]
---

Every conversation I have about fixing enterprise agents arrives at the same fix: a smarter LLM. Bigger context window. Better tool use. More memory. That is the wrong lever. My agent was never too dumb. I have been sending it into my business without a map.

## The Agent Has No Map

The metaphor I keep coming back to is **the map**.

Drop a hiker into an unfamiliar wilderness. They might find a way through after long detours and wasted daylight, or, more likely, give up entirely. Hand them a map and everything changes. They can navigate the terrain and chart a path across ridges, rivers, and peaks. The map is what turns raw capability into competence on ground you do not know.

Right now I am dropping my agents into the rugged landscape of my enterprise stack, a wilderness of isolated silos, hidden pitfalls, and disconnected legacy ruins, with no map at all.

They don't know which database is the system of record. They don't know whether *customer* in the CRM is the same thing as *account* in billing. They don't know that an order can't ship before it's paid, or that only a manager can sign off a refund. They have no trail guide.

Agents like Claude, Codex or OpenClaw aren't failing because they lack the intelligence to climb. They are failing because I send them into terrain they cannot read.

## What a Complete Map Holds

A map only works if it is complete, because my agent will not leave a blank space blank. It acts on what it can see, and when it hits a gap, it confidently hallucinates the rest. Instead of stopping, it invents data and runs the business in circles, or steers operations off a cliff.

To navigate that wilderness, the map needs four parts. Watch a single payment move through them.

- **Entities** give the agent its nouns. A *customer*, an *order*, a *payment*, a *refund*: defined things with defined fields. The agent always knows what it is holding, and never invents a customer that doesn't exist.
- **Relationships** give it the connections. A payment belongs to an order, an order to a customer, a refund to a payment. The agent can trace a refund back to the exact charge it reverses instead of guessing at a join.
- **Business rules** give it the bounds of what is valid. A refund can never exceed the original payment, so the moment the agent drafts one, the business's own logic checks it.
- **Permitted actions** give it the bounds of its authority. It can prepare a refund, but signing off anything above the limit belongs to a manager, so it escalates instead of overstepping.

Those four are what let an agent move through my business and act the way a careful employee would.

## I Am Not the Only One

Over the last few weeks the same idea has started to surface elsewhere.

Just last month, in a [press release on how missing semantics break AI agents](https://www.gartner.com/en/newsroom/press-releases/2026-05-11-gartner-says-lack-of-semantics-causes-inaccurate-artificial-intelligence-agents-and-wasted-spending), Gartner put a number on it: organizations that prioritize semantics in their data by 2027 will see agent accuracy improve by up to 80% while the cost of running those agents drops by up to 60%. Read those numbers closely. The gain does not come from a smarter model. It comes because the environment became navigable. Gartner says it plainly: agents need *"a clear understanding of the specific relationships and rules within an organization's data."* They call this a 'context layer.' I call it a map.

Besides the market-defining analysts, a Microsoft chief architect is making the same case. Writing [in CIO](https://www.cio.com/article/4169618/the-next-enterprise-architecture-asset-ontologies-for-ai.html) last month, Stephen Kaufman sketched almost the same map part for part: a semantic contract of entities, relationships, rules, and permitted actions bound directly to the data.

His sharpest point is the one I keep claiming: it belongs in the data layer, not the AI layer. An ontology, which is essentially the smaller sibling of a full map, becomes dangerously out of sync when trapped inside a single AI tool. Read it with the obvious caveat that his strategy aligns with Microsoft's own platform direction, so it is a vendor pointing the same way rather than independent proof. Still, when an analyst firm and a platform architect both demand a separate semantic foundation in the same month, it is no longer only my metaphor.

## Build It in the Data, Not the Agent

So back to that wrong lever. The fix was never a bigger LLM. It is the layer the agent walks into. Right now AI budgets go toward bigger context windows, more tokens, and smarter prompts, and almost none of it reaches the data layer itself. We are paying the wrong bill.

The reason the map belongs in the data, and not bolted onto the AI, is drift. A business changes every week: new products, new rules, new exceptions. A map kept as a separate layer on top of the data goes stale within days, and a stale map brings back the exact same hallucination problem, sending the agent off-trail yet again.

The only map that stays true is one that is part of the data itself. Build it there and every agent and every legacy tool reads the same map, and it changes as the business does.

LLMs become commodities. My business logic is the asset. Agents will be swapped out many times over the coming years. Though they are the disposable part, the map is what must endure.

## The Era of the Map

I ended the first post by writing that *the era of the single semantic foundation must begin now.* This is its blueprint. Not a smarter LLM. Not a bloated Frankenstack. **A complete semantic model with entities, relationships, rules, and permitted actions, living next to my data and read by every agent that touches my business.**

In the next post I'll open one of the models I run my own product on and show you exactly what one looks like.

For now the thesis is a single sentence:

> A complete semantic model is all my agents need.
