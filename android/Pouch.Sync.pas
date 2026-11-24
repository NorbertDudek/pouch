unit Pouch.Sync;

// Sync with the self-hosted PHP server (server/index.php) — a port of
// extension/lib/remote.js and extension/lib/sync.js from the add-on.
//
// Flow: push local changes (deletions included), then pull changes
// from the server since the last stored cursor.
// TPouchSync.Run blocks — call it from a background thread.

interface

uses
  System.SysUtils,
  System.JSON,
  Pouch.Store;

type
  TSyncResult = record
    Enabled: Boolean;
    Ok: Boolean;
    Error: string;
    LastSyncAt: Int64;
    /// <summary>True when anything came from the server (the list may need a refresh).</summary>
    Received: Boolean;
  end;

  EPouchServer = class(Exception);

  TPouchSync = class
  public
    /// <summary>Never raises; the outcome is in the result and in the store's sync state.</summary>
    class function Run(const Store: TPouchStore): TSyncResult; static;
    /// <summary>Checks the address and token; raises EPouchServer with a readable message.</summary>
    class procedure Ping(const Settings: TPouchSettings); static;
  end;

/// <summary>Normalizes the entered address into the form requests are sent to; '' stays ''.</summary>
function NormalizeServerUrl(const Raw: string): string;

implementation

uses
  System.Classes,
  System.Net.URLClient,
  System.Net.HttpClient,
  System.NetEncoding;

const
  TimeoutMs = 20000;
  PushBatch = 50;
  TokenHeader = 'X-Schowek-Token';

function NormalizeServerUrl(const Raw: string): string;
var
  Text: string;
  Lower: string;
  Cut: Integer;
  SchemeEnd: Integer;
  PathStart: Integer;
  Path: string;
begin
  Text := Raw.Trim;
  if Text = '' then
    Exit('');
  Lower := Text.ToLower;
  if not (Lower.StartsWith('http://') or Lower.StartsWith('https://')) then
    raise EPouchServer.Create('The server address must start with https:// or http://.');

  Cut := Text.IndexOfAny(['?', '#']);
  if Cut >= 0 then
    Text := Text.Substring(0, Cut);

  SchemeEnd := Text.IndexOf('://') + 3;
  PathStart := Text.IndexOf('/', SchemeEnd);
  if PathStart < 0 then
  begin
    if Text.Length = SchemeEnd then
      raise EPouchServer.Create('Invalid server address.');
    Exit(Text + '/');
  end;

  // A directory address without a trailing "/" would end in a redirect that drops the POST.
  Path := Text.Substring(PathStart).ToLower;
  if not Path.EndsWith('/') and not Path.EndsWith('.php') then
    Text := Text + '/';
  Result := Text;
end;

type
  TServerClient = class
  private
    FEndpoint: string;
    FToken: string;
    FHttp: THTTPClient;
    function Request(const Method, Query: string; const Body: TJSONObject): TJSONObject;
  public
    constructor Create(const Settings: TPouchSettings);
    destructor Destroy; override;
    procedure Ping;
    procedure Push(const Items: TPouchItems);
    /// <summary>Returns the records; Cursor and More are updated from the response.</summary>
    function Pull(var Cursor: Int64; out More: Boolean): TPouchItems;
  end;

constructor TServerClient.Create(const Settings: TPouchSettings);
begin
  inherited Create;
  FEndpoint := NormalizeServerUrl(Settings.ServerUrl);
  FToken := Settings.Token;
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := TimeoutMs;
  FHttp.SendTimeout := TimeoutMs;
  FHttp.ResponseTimeout := TimeoutMs;
  FHttp.UserAgent := 'Pouch-Android';
end;

destructor TServerClient.Destroy;
begin
  FHttp.Free;
  inherited;
end;

function TServerClient.Request(const Method, Query: string; const Body: TJSONObject): TJSONObject;
var
  Url: string;
  Headers: TNetHeaders;
  Response: IHTTPResponse;
  Content: TStringStream;
  Parsed: TJSONValue;
  ErrorValue: TJSONValue;
begin
  Url := FEndpoint;
  if Query <> '' then
    Url := Url + '?' + Query;

  Content := nil;
  try
    try
      if Body <> nil then
      begin
        Content := TStringStream.Create(Body.ToJSON, TEncoding.UTF8, False);
        Headers := [TNameValuePair.Create(TokenHeader, FToken),
          TNameValuePair.Create('Content-Type', 'application/json')];
        Response := FHttp.Post(Url, Content, nil, Headers);
      end
      else
      begin
        Headers := [TNameValuePair.Create(TokenHeader, FToken),
          TNameValuePair.Create('Cache-Control', 'no-cache')];
        Response := FHttp.Get(Url, nil, Headers);
      end;
    except
      on E: Exception do
        raise EPouchServer.Create('Cannot connect to the server.');
    end;
  finally
    Content.Free;
  end;

  if Response.StatusCode = 401 then
    raise EPouchServer.Create('The server rejected the token.');

  Parsed := nil;
  try
    Parsed := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
  except
    // response is not JSON — handled below
  end;
  if not (Parsed is TJSONObject) then
  begin
    Parsed.Free;
    raise EPouchServer.CreateFmt('No Pouch server responds at this address (HTTP %d).',
      [Response.StatusCode]);
  end;

  Result := TJSONObject(Parsed);
  if (Response.StatusCode < 200) or (Response.StatusCode > 299)
    or not (Result.GetValue('ok') is TJSONTrue) then
  begin
    ErrorValue := Result.GetValue('error');
    try
      if ErrorValue is TJSONString then
        raise EPouchServer.Create(TJSONString(ErrorValue).Value)
      else
        raise EPouchServer.CreateFmt('Server error (HTTP %d).', [Response.StatusCode]);
    finally
      Result.Free;
    end;
  end;
end;

procedure TServerClient.Ping;
var
  Data: TJSONObject;
  App: TJSONValue;
begin
  Data := Request('GET', 'ping=1', nil);
  try
    App := Data.GetValue('app');
    if not (App is TJSONString) or (TJSONString(App).Value <> 'schowek') then
      raise EPouchServer.Create('No Pouch server responds at this address.');
  finally
    Data.Free;
  end;
end;

procedure TServerClient.Push(const Items: TPouchItems);
var
  Body: TJSONObject;
  List: TJSONArray;
  Item: TPouchItem;
begin
  Body := TJSONObject.Create;
  try
    List := TJSONArray.Create;
    Body.AddPair('items', List);
    for Item in Items do
      List.AddElement(Item.ToJson);
    Request('POST', '', Body).Free;
  finally
    Body.Free;
  end;
end;

function TServerClient.Pull(var Cursor: Int64; out More: Boolean): TPouchItems;
var
  Data: TJSONObject;
  List: TJSONValue;
  Element: TJSONValue;
  Item: TPouchItem;
  Count: Integer;
  CursorValue: TJSONValue;
begin
  Data := Request('GET', 'since=' + IntToStr(Cursor), nil);
  try
    List := Data.GetValue('items');
    if not (List is TJSONArray) then
      raise EPouchServer.Create('Invalid server response.');

    SetLength(Result, TJSONArray(List).Count);
    Count := 0;
    for Element in TJSONArray(List) do
      if TPouchItem.TryFromJson(Element, Item) then
      begin
        Item.Dirty := False;
        Result[Count] := Item;
        Inc(Count);
      end;
    SetLength(Result, Count);

    CursorValue := Data.GetValue('cursor');
    if CursorValue is TJSONNumber then
      Cursor := TJSONNumber(CursorValue).AsInt64;
    More := Data.GetValue('more') is TJSONTrue;
  finally
    Data.Free;
  end;
end;

procedure PushPending(const Client: TServerClient; const Store: TPouchStore);
var
  Outgoing: TPouchItems;
  Batch: TPouchItems;
  Stamps: TArray<TSyncStamp>;
  Start: Integer;
  I: Integer;
begin
  Outgoing := Store.Pending;
  Start := 0;
  while Start < Length(Outgoing) do
  begin
    Batch := Copy(Outgoing, Start, PushBatch);
    Client.Push(Batch);
    SetLength(Stamps, Length(Batch));
    for I := 0 to High(Batch) do
    begin
      Stamps[I].Id := Batch[I].Id;
      Stamps[I].UpdatedAt := Batch[I].UpdatedAt;
    end;
    Store.MarkSynced(Stamps);
    Inc(Start, PushBatch);
  end;
end;

{ TPouchSync }

class procedure TPouchSync.Ping(const Settings: TPouchSettings);
var
  Client: TServerClient;
begin
  Client := TServerClient.Create(Settings);
  try
    Client.Ping;
  finally
    Client.Free;
  end;
end;

class function TPouchSync.Run(const Store: TPouchStore): TSyncResult;
var
  Settings: TPouchSettings;
  Client: TServerClient;
  Cursor: Int64;
  More: Boolean;
  Incoming: TPouchItems;
begin
  Result := Default(TSyncResult);
  Settings := Store.GetSettings;
  if Settings.ServerUrl = '' then
    Exit;
  Result.Enabled := True;

  try
    Client := TServerClient.Create(Settings);
    try
      PushPending(Client, Store);

      repeat
        Cursor := Store.GetSyncState.Cursor;
        Incoming := Client.Pull(Cursor, More);
        if Length(Incoming) > 0 then
        begin
          Store.ApplyRemote(Incoming);
          Result.Received := True;
        end;
        Store.SetCursor(Cursor);
      until not More;

      // Merging may have deleted duplicates of the same page — send those deletions right away.
      if Result.Received then
        PushPending(Client, Store);
    finally
      Client.Free;
    end;

    Result.Ok := True;
    Result.LastSyncAt := NowMs;
    Store.SetSyncResult(Result.LastSyncAt, '');
  except
    on E: Exception do
    begin
      Result.Ok := False;
      Result.Error := E.Message;
      Store.SetSyncResult(0, E.Message);
    end;
  end;
end;

end.
