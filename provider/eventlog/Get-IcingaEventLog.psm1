Import-IcingaLib icinga\exception;

function Get-IcingaEventLog()
{
    param(
        [string]$LogName,
        [array]$IncludeEventId   = @(),
        [array]$ExcludeEventId   = @(),
        [array]$IncludeUsername  = @(),
        [array]$ExcludeUsername  = @(),
        [array]$IncludeEntryType = @(),
        [array]$ExcludeEntryType = @(),
        [array]$IncludeMessage   = @(),
        [array]$ExcludeMessage   = @(),
        [array]$IncludeSource    = @(),
        [array]$ExcludeSource    = @(),
        $After,
        $Before,
        [bool]$DisableTimeCache
    );

    if ([string]::IsNullOrEmpty($LogName)) {
        Exit-IcingaThrowException -ExceptionType 'Input' -ExceptionThrown $IcingaExceptions.Inputs.EventLog -Force;
    }

    [hashtable]$EventLogArguments = @{
        LogName = $LogName;
    };

    # This will generate a unique hash for each possible configured EventLog check to store the last check time for each of these checks
    [string]$CheckHash    = (Get-StringSha1 ($LogName + $IncludeEventId + $ExcludeEventId + $IncludeUsername + $ExcludeUsername + $IncludeEntryType + $ExcludeEntryType + $IncludeMessage + $ExcludeMessage)) + '.lastcheck';
    [string]$EventsAfter  = $null;
    [string]$EventsBefore = $null;

    if ([string]::IsNullOrEmpty($After) -and $DisableTimeCache -eq $FALSE) {
        $time = Get-IcingaCacheData -Space 'provider' -CacheStore 'eventlog' -KeyName $CheckHash;
        Set-IcingaCacheData -Space 'provider' -CacheStore 'eventlog' -KeyName $CheckHash -Value ((Get-Date).ToFileTime());

        if ($null -ne $time) {
            $EventsAfter = ([datetime]::FromFileTime($time)).ToString('yyyy\/MM\/dd HH:mm:ss');
        }
    }

    # In case we are not having cached time execution and not have not overwritten the timestamp, only fetch values from 2 hours in the past
    if ([string]::IsNullOrEmpty($EventsAfter)) {
        if ([string]::IsNullOrEmpty($After)) {
            [string]$EventsAfter = ([datetime]::Now.Subtract([TimeSpan]::FromHours(2))).ToString('yyyy\/MM\/dd HH:mm:ss');
        } else {
            if ((Test-Numeric $After)) {
                $EventsAfter = ([datetime]::Now.Subtract([TimeSpan]::FromSeconds($After))).ToString('yyyy\/MM\/dd HH:mm:ss');
            } else {
                $EventsAfter = $After;
            }
        }
    }

    if ([string]::IsNullOrEmpty($Before) -eq $FALSE) {
        if ((Test-Numeric $Before)) {
            $EventsBefore = ([datetime]::Now.Subtract([TimeSpan]::FromSeconds($Before))).ToString('yyyy\/MM\/dd HH:mm:ss');
        } else {
            $EventsBefore = $Before;
        }
    }

    if ($null -ne $IncludeUsername -And $IncludeUsername.Count -ne 0) {
        $EventLogArguments.Add('UserName', $IncludeUsername);
    }
    if ($null -ne $IncludeEntryType -And $IncludeEntryType.Count -ne 0) {
        $EventLogArguments.Add('EntryType', $IncludeEntryType);
    }
    if ([string]::IsNullOrEmpty($EventsAfter) -eq $FALSE) {
        $EventLogArguments.Add('After', $EventsAfter);
    }
    if ([string]::IsNullOrEmpty($EventsBefore) -eq $FALSE) {
        $EventLogArguments.Add('Before', $EventsBefore);
    }

    try {
        $events = Get-EventLog @EventLogArguments -ErrorAction Stop;
    } catch {
        Exit-IcingaThrowException -InputString $_.Exception -StringPattern 'ParameterBindingValidationException' -ExceptionType 'Input' -ExceptionThrown $IcingaExceptions.Inputs.EventLog;
        Exit-IcingaThrowException -InputString $_.Exception -StringPattern 'System.InvalidOperationException' -CustomMessage (-Join $LogName) -ExceptionType 'Input' -ExceptionThrown $IcingaExceptions.Inputs.EventLogLogName;
    }

    if ($null -ne $IncludeEventId -Or $null -ne $ExcludeEventId -Or $null -ne $ExcludeUsername -Or $null -ne $ExcludeEntryType -Or $null -ne $ExcludeMessage -Or $null -ne $IncludeMessage -Or $null -ne $IncludeSource -Or $null -ne $ExcludeSource) {
        $filteredEvents = @();
        foreach ($event in $events) {
            # Filter out excluded event IDs
            if ($ExcludeEventId.Count -ne 0 -And $ExcludeEventId -contains $event.EventId) {
                continue;
            }

            # Filter out excluded events by username
            if ($ExcludeUsername.Count -ne 0 -And $ExcludeUsername -contains $event.UserName) {
                continue;
            }

            # Filter out excluded events by entry type (Error, Warning, ...)
            if ($ExcludeEntryType.Count -ne 0 -And $ExcludeEntryType -contains $event.EntryType) {
                continue;
            }

            # Filter out excluded events message source
            if ($ExcludeSource.Count -ne 0 -And $ExcludeSource -contains $event.Source) {
                continue;
            }

            [bool]$skip = $FALSE;
            foreach ($exMessage in $ExcludeMessage) {
                # Filter out excluded event IDs
                if ([string]$event.Message -like [string]$exMessage) {
                    $skip = $TRUE;
                    break;
                }
            }

            if ($skip) {
                continue;
            }

            $skip = $TRUE;

            if ($IncludeMessage.Count -ne 0) {
                foreach ($inMessage in $IncludeMessage) {
                    # Filter for specific message content
                    if ([string]$event.Message -like [string]$inMessage) {
                        $skip = $FALSE;
                        break;
                    }
                }
            } else {
                $skip = $FALSE;
            }

            # We might be looking for specific event ids
            if ($IncludeEventId.Count -ne 0 -And $IncludeEventId -NotContains $event.EventId) {
                $skip = $TRUE;
            }

            # We might be looking for specific event sources
            if ($IncludeSource.Count -ne 0 -And $IncludeSource -NotContains $event.Source) {
                $skip = $TRUE;
            }

            if ($skip) {
                continue;
            }

            $filteredEvents += $event;
        }

        $events = $filteredEvents;
    }

    $groupedEvents = @{
        'eventlog' = @{};
        'events'   = @{};
    };

    foreach ($event in $events) {
        [string]$EventIdentifier = [string]::Format('{0}-{1}',
            $event.EventId,
            $event.Source
        );

        [string]$EventHash = Get-StringSha1 $EventIdentifier;

        if ($groupedEvents.eventlog.ContainsKey($EventHash) -eq $FALSE) {
            $groupedEvents.eventlog.Add(
                $EventHash,
                @{
                    NewestEntry = $event.TimeGenerated;
                    OldestEntry = $event.TimeGenerated;
                    EventId     = $event.EventId;
                    Message     = $event.Message;
                    Severity    = $event.EntryType;
                    Source      = $event.Source;
                    Count       = 1;
                }
            );
        } else {
            $groupedEvents.eventlog[$EventHash].OldestEntry = $event.TimeGenerated;
            $groupedEvents.eventlog[$EventHash].Count       += 1;
        }

        if ($groupedEvents.events.ContainsKey($event.EventId) -eq $FALSE) {
            $groupedEvents.events.Add($event.EventId, 1);
        } else {
            $groupedEvents.events[$event.EventId] += 1;
        }
    }

    return $groupedEvents;
}
