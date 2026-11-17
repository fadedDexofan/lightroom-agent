on run
    tell application "Adobe Lightroom Classic" to activate

    tell application "System Events"
        tell process "Adobe Lightroom Classic"
            if not (exists window "Lightroom Plug-in Manager") then
                click (first menu item of menu "File" of menu bar 1 whose name starts with "Plug-in Manager")
            end if

            repeat 20 times
                if exists window "Lightroom Plug-in Manager" then exit repeat
                delay 0.25
            end repeat
            if not (exists window "Lightroom Plug-in Manager") then error "Plug-in Manager did not open"

            tell window "Lightroom Plug-in Manager"
                set targetRow to missing value
                repeat with candidate in (rows of table 1 of scroll area 1)
                    if (value of static text 1 of candidate) starts with "Lightroom Agent" then
                        set targetRow to candidate
                        exit repeat
                    end if
                end repeat
                if targetRow is missing value then error "Lightroom Agent is not installed"

                click targetRow
                click button "Reload Plug-in" of scroll area 2
            end tell

            set closed to false
            repeat 20 times
                delay 0.5
                try
                    click button "Done" of window "Lightroom Plug-in Manager"
                    set closed to true
                    exit repeat
                end try
            end repeat
            if not closed then error "Reload requested, but Plug-in Manager could not be closed"
        end tell
    end tell

    return "Reload requested; check the plugin sockets and an MCP tool call"
end run
