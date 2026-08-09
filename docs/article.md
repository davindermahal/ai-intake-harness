# Article Brief

## Working Title

Building an agentic workflow with AI and JIRA

## Why I'm writing this

I am experimenting with AI and building an agentic workflow with the ability to control agents from JIRA.

I want readers to understand the purpose and mental model, and then the implementation details.

## Audience

Intermediate developers learning AI techniques and workflows.

## Key Takeaways

- AI Agents can be used to automate development by using JIRA (or another ticketing system)
- It's important to provide details and lots of information in the JIRA description. Be Specific, or, if you are unsure, ask questions and for feedback to get a dialog going.
- Isolation for docker containers, databases, and worktrees is crutional for this to work.
- Being able to queue work from a mobile phone using the jIRA app, come back to the computer to completed tasks.

<!-- ## Do Not Discuss -->

<!-- - Internal company architecture.
- Database schema.
- Queue implementation.
- AWS services.
- Proprietary reconciliation algorithms. -->

## Suggested Diagrams

- JIRA workflow.
- Worktree implementation with docker apps and databases.

## Call to Action

Encourage readers to think about how they could control Ai agents for automated workflows and application development.

## Next steps
- Write more about the detailed implementation
- To specify the AI provider and model (OpenAI, Anthropic, or local LLM)
- Publish the harness to github so it can be reused
- Reuse it in another project as I've only set this up in my personal app - this has not harness has not been tested in another project.