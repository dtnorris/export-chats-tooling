## **Daily commands to save/scrape chatgpt context**

1. cd /Users/davidnorris/code/export-chats-tooling && ruby capture_watch.rb

2. caffeinate -dimsu

3. cd /Users/davidnorris/code/export-chats-tooling && pbcopy < project_inventory.js
    1. (load the Adventure Finder project page in the UI), (paste the copied JS
       code and run)

4. (move the newly downloaded inventory .json and .csv into:
	1. /Users/davidnorris/code/export-chats-data)

5. cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb
	1. This regenerates .state/project_batch_console.js from the new inventory.

6. cd /Users/davidnorris/code/export-chats-tooling && pbcopy <
   .state/project_batch_console.js
	1. (load the Adventure Finder project page in the UI)
	2. (paste the copied JS code and run)

7. *After the batch finishes:*
	1. cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb
	2. (look to confirm **Pending IDs: 0**)
