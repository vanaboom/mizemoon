set sh1 to "launchctl unload -w /Library/LaunchDaemons/ir.mizemoon.mizemoon_service.plist;"
set sh2 to "/bin/rm /Library/LaunchDaemons/ir.mizemoon.mizemoon_service.plist;"
set sh3 to "/bin/rm /Library/LaunchAgents/ir.mizemoon.mizemoon_server.plist;"

set sh to sh1 & sh2 & sh3
do shell script sh with prompt "MizeMoon wants to unload daemon" with administrator privileges