on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/ir.mizemoon.mizemoon_service.plist && chown root:wheel /Library/LaunchDaemons/ir.mizemoon.mizemoon_service.plist;"

  set sh2 to "echo " & quoted form of agent_file & " > /Library/LaunchAgents/ir.mizemoon.mizemoon_server.plist && chown root:wheel /Library/LaunchAgents/ir.mizemoon.mizemoon_server.plist;"

  set sh3 to "cp -rf /Users/" & user & "/Library/Preferences/ir.mizemoon.mizemoon/MizeMoon.toml /var/root/Library/Preferences/ir.mizemoon.mizemoon/;"

  set sh4 to "cp -rf /Users/" & user & "/Library/Preferences/ir.mizemoon.mizemoon/MizeMoon2.toml /var/root/Library/Preferences/ir.mizemoon.mizemoon/;"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/ir.mizemoon.mizemoon_service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "MizeMoon wants to install daemon and agent" with administrator privileges
end run
