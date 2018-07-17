function Engine
{
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Engine,

        [Parameter()]
        [scriptblock]
        $ScriptBlock = $null
    )

    $PodeSession.ViewEngine.Extension = $Engine.ToLowerInvariant()
    $PodeSession.ViewEngine.Script = $ScriptBlock
}

function Start-WebServer
{
    param (
        [switch]
        $Https
    )

    # grab the protocol
    $protocol = 'http'
    if ($Https) {
        $protocol = 'https'
    }

    # grab the ip address
    $_ip = "$($PodeSession.IP.Address)"
    if ($_ip -ieq '0.0.0.0') {
        $_ip = '*'
    }

    # grab the port
    $port = $PodeSession.IP.Port
    if ($port -eq 0) {
        $port = (iftet $Https 8443 8080)
    }

    # create the listener on http and/or https
    $listener = New-Object System.Net.HttpListener

    try
    {
        # start listening on ip:port
        $listener.Prefixes.Add("$($protocol)://$($_ip):$($port)/")
        $listener.Start()
    }
    catch {
        $Error[0] | Out-Default

        if ($null -ne $Listener) {
            if ($Listener.IsListening) {
                $Listener.Stop()
            }

            dispose $Listener -Close
        }

        throw $_.Exception
    }

    # state where we're running
    Write-Host "Listening on $($protocol)://$($PodeSession.IP.Name):$($port)/ [$($PodeSession.Threads) thread(s)]" -ForegroundColor Yellow

    # script for listening out for incoming requests
    $listenScript = {
        param (
            [Parameter(Mandatory=$true)]
            [ValidateNotNull()]
            $Listener,

            [Parameter(Mandatory=$true)]
            [int]
            $ThreadId
        )

        try
        {
            while ($Listener.IsListening -and !$PodeSession.Tokens.Cancellation.IsCancellationRequested)
            {
                # get request and response
                $task = $Listener.GetContextAsync()
                $task.Wait($PodeSession.Tokens.Cancellation.Token)

                $context = $task.Result
                $request = $context.Request
                $response = $context.Response

                # clear session
                $WebSession = @{}
                $WebSession.Response = $response
                $WebSession.Request = $request
                $WebSession.Lockable = $PodeSession.Lockable

                # get url path and method
                $path = ($request.RawUrl -isplit "\?")[0]
                $method = $request.HttpMethod.ToLowerInvariant()

                # setup the base request to log later
                $logObject = @{
                    'Host' = $request.RemoteEndPoint.Address.IPAddressToString;
                    'RfcUserIdentity' = '-';
                    'User' = '-';
                    'Date' = [DateTime]::Now.ToString('dd/MMM/yyyy:HH:mm:ss zzz');
                    'Request' = @{
                        'Method' = $method.ToUpperInvariant();
                        'Resource' = $path;
                        'Protocol' = "HTTP/$($request.ProtocolVersion)";
                        'Referrer' = $request.UrlReferrer;
                        'Agent' = $request.UserAgent;
                    };
                    'Response' = @{
                        'StatusCode' = '-';
                        'StautsDescription' = '-'
                        'Size' = '-';
                    };
                }

                # ensure the request ip is allowed
                if (!(Test-IPAccess -IP $request.RemoteEndPoint.Address)) {
                    status 403
                }

                # check to see if the path is a file, so we can check the public folder
                elseif ((Split-Path -Leaf -Path $path).IndexOf('.') -ne -1) {
                    $path = Join-ServerRoot 'public' $path
                    Write-ToResponseFromFile -Path $path
                }

                else {
                    # ensure the path has a route
                    $route = Get-PodeRoute -HttpMethod $method -Route $path
                    if ($null -eq $route -or $null -eq $route.Logic) {
                        status 404
                    }

                    # run the scriptblock
                    else {
                        # read any post data
                        $data = stream ([System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)) {
                            param($r)
                            return $r.ReadToEnd()
                        }

                        # attempt to parse that data
                        $data = ConvertFrom-PodeContent -ContentType $request.ContentType -Content $data

                        # set session data
                        $WebSession.Data = $data
                        $WebSession.Query = $request.QueryString
                        $WebSession.Parameters = $route.Parameters

                        # invoke route
                        Invoke-ScriptBlock -ScriptBlock (($route.Logic).GetNewClosure()) -Arguments $WebSession -Scoped
                    }
                }

                # close response stream (check if exists, as closing the writer closes this stream on unix)
                if ($response.OutputStream) {
                    dispose $response.OutputStream -Close -CheckNetwork
                }

                # add the log object to the list
                $logObject.Response.StatusCode = $response.StatusCode
                $logObject.Response.StatusDescription = $response.StatusDescription

                if ($response.ContentLength64 -gt 0) {
                    $logObject.Response.Size = $response.ContentLength64
                }

                if (!$PodeSession.DisableLogging -and ($PodeSession.Loggers | Measure-Object).Count -gt 0) {
                    $PodeSession.RequestsToLog.Add($logObject) | Out-Null
                }
            }
        }
        catch [System.OperationCanceledException] {}
        catch {
            $Error[0] | Out-Default
            throw $_.Exception
        }
    }

    # start the runspace for listening on x-number of threads
    1..$PodeSession.Threads | ForEach-Object {
        Add-PodeRunspace $listenScript -Parameters @{ 'Listener' = $listener; 'ThreadId' = $_ }
    }

    # script to keep web server listening until cancelled
    $waitScript = {
        param (
            [Parameter(Mandatory=$true)]
            [ValidateNotNull()]
            $Listener
        )

        try
        {
            while ($Listener.IsListening -and !$PodeSession.Tokens.Cancellation.IsCancellationRequested)
            {
                Start-Sleep -Seconds 1
            }
        }
        catch [System.OperationCanceledException] {}
        catch {
            $Error[0] | Out-Default
            throw $_.Exception
        }
        finally {
            if ($null -ne $Listener) {
                if ($Listener.IsListening) {
                    $Listener.Stop()
                }

                dispose $Listener -Close
            }
        }
    }

    Add-PodeRunspace $waitScript -Parameters @{ 'Listener' = $listener }
}