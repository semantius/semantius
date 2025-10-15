In the late 80s relational databases allowed to manage data independently from specific applications. This for the first time allowed to have a "central source of truth". Procedural code, such as PL/SQL, allowed to ensure consistency by applying business rules for all data.

The volume of data managed in database servers grew fast. Initially most database applications had two tiers: the database and the client with business logic and user interface. The high licenses prices for relational databases became a restricting factor for client server computing in the early 90s. One way to keep the license costs at bay was separating business logic into separate servers. Business logic moved out of the database into its own tier, the application server.

Database servers initially did not provide build-in, fine grained, per row or column permissions management. When that was added in 1999 by Oracle or by Microsoft with the release of with the release of SQL Server 2016 the ship was mostly sailed. Permissions and business logic was separated from the database and mostly managed in the application tier.

Development changed from "database first" to "code first". So any change in the data model, was defined in code. That caused frictions and silos as applications are written in different languages like Java or C#. The information about the data structures was buried in multiple codebases, written in different languages.

PostgreSQL was initially released in 1997. Unlike MySQL it has a permissive license, so it has no real license constraints. With the release of replication in of logical replication with version 10 in 2017, its march to dominance in the enterprise space became unstoppable.

In 2025 your data is either isolated in a multitude of SaaS solutions and only accessible by non standardized APIs or in internal data silos hidden behind various paradigms like object relational mappers (ORM).

Large multinational organizations or internet companies have to manage staggering volumes of data requiring technologies like data warehouses or data lakes. Most organizations have data volumes which could be easily managed by a single PostgreSQL instance.

I think it's time to revive and perfect the lost art of database first. Have all data in a central database. Enforce consistency by business rules in the database. Central access control to all data. One API to access all data. Empower LLM Agents by granting secure access. Permissive licensing not prohibiting any use case. Use it in the cloud or run it on your own.