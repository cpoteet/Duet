tell application "Mail"
  repeat with m in (every outgoing message)
    if subject of m is "Team demo on Monday" then close m saving no
  end repeat
  set body to "Hi all," & return & return & "Monday's team demo is at 10 in the main conference room. Each team gets five minutes to show what they shipped this sprint, then we'll take questions." & return & return & "I'll kick things off with something light to get everyone talking."
  set m to make new outgoing message with properties {subject:"Team demo on Monday", content:body, visible:true}
  delay 1
  set bounds of front window to {345, 165, 1125, 745}
end tell
