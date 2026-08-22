on run argv
if (count of argv) is 0 then error "缺少 iPad 设备名称"
set targetDevice to item 1 of argv
do shell script "/usr/bin/open 'x-apple.systempreferences:com.apple.preference.displays'"
tell application "System Settings" to activate
delay 1.5

tell application "System Events"
    tell process "System Settings"
        set frontmost to true
        repeat 20 times
            if exists front window then exit repeat
            delay 0.25
        end repeat
        if not (exists front window) then error "没有找到显示器设置窗口"

        -- macOS 26/27（Liquid Glass）显示器面板。
        try
            tell group 1 of group 3 of splitter group 1 of group 1 of front window
                click menu button 1
                delay 0.6
                set menuNames to name of every menu item of menu 1 of menu button 1
                repeat with menuIndex from (count of menuNames) to 1 by -1
                    set candidateName to item menuIndex of menuNames as text
                    if candidateName contains targetDevice then
                        click menu item menuIndex of menu 1 of menu button 1
                        return "selected:" & candidateName
                    end if
                end repeat
                key code 53
            end tell
        on error liquidError
            try
                key code 53
            end try
        end try

        -- macOS 13–15 旧显示器面板。
        try
            tell group 1 of group 2 of splitter group 1 of group 1 of front window
                click pop up button 1
                delay 0.6
                set menuNames to name of every menu item of menu 1 of pop up button 1
                repeat with menuIndex from (count of menuNames) to 1 by -1
                    set candidateName to item menuIndex of menuNames as text
                    if candidateName contains targetDevice then
                        click menu item menuIndex of menu 1 of pop up button 1
                        return "selected:" & candidateName
                    end if
                end repeat
                key code 53
            end tell
        on error legacyError
            try
                key code 53
            end try
        end try
    end tell
end tell

error "显示器菜单中没有找到 " & targetDevice
end run
