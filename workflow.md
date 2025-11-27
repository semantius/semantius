web hook receiver, web hook sender, function call, human in the loop, maybe: send email
sync queue with call back ?


- workflow server is a seperate service
- trigger with dblink  generic user + password + apikey in function check
- human in the loop / approvals
- callback with m2m token
- generic steps interface with execution loop 
- try cloudflare & triggerdev? inngest? restate?





- tenant: flow setting: flow host or url, flow apikey
- flowendinge: tenant url, m2m urld, user, pass
- audit log & flow -> send to flow  flowengine
- received web hooks, stored in db of tenant, processed state, kicks off process task
- tasks: fetch external, execute rpc, waitFor, transform -- input json, output json, context json, config json



https://neon.com/blog/multi-tenant-rag
https://www.inngest.com/docs/guides/user-defined-workflows