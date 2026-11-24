unit Pouch.Store;

// Local data layer — a port of extension/lib/store.js from the add-on.
//
// The record model is the same as in the add-on and on the server:
//   Id         – UUID assigned locally (stable across devices)
//   Url, Title, Favicon
//   CreatedAt  – ms since the epoch
//   UpdatedAt  – ms since the epoch; used to resolve conflicts (newer wins)
//   DeletedAt  – 0 or the deletion time (a "tombstone", so the deletion can
//                propagate to the server and other devices)
//   Dirty      – True while the change has not been sent to the server yet
//
// Everything (items, sync state, settings) lives in one JSON file. Every method
// is thread-safe, because sync runs on a background thread.

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults;

type
  TPouchItem = record
    Id: string;
    Url: string;
    Title: string;
    Favicon: string;
    CreatedAt: Int64;
    UpdatedAt: Int64;
    DeletedAt: Int64;
    Dirty: Boolean;
    function IsDeleted: Boolean; inline;
    /// <summary>JSON in the server's format (without Dirty).</summary>
    function ToJson: TJSONObject;
    /// <summary>Reads a record in the server's format; False when it is invalid.</summary>
    class function TryFromJson(const Value: TJSONValue; out Item: TPouchItem): Boolean; static;
  end;

  TPouchItems = TArray<TPouchItem>;

  TSyncStamp = record
    Id: string;
    UpdatedAt: Int64;
  end;

  TSyncState = record
    Cursor: Int64;
    LastSyncAt: Int64;
    LastError: string;
  end;

  TPouchSettings = record
    ServerUrl: string;
    Token: string;
  end;

  TSaveResult = record
    Item: TPouchItem;
    Existed: Boolean;
  end;

  TPouchStore = class
  private
    FLock: TCriticalSection;
    FItems: TList<TPouchItem>;
    FSyncState: TSyncState;
    FSettings: TPouchSettings;
    FFileName: string;
    procedure Load;
    procedure Persist;
    function IndexOfId(const Id: string): Integer;
    function IndexOfUrl(const Url: string): Integer;
    class procedure Touch(var Item: TPouchItem); static;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    /// <summary>Active (not deleted) items, newest first.</summary>
    function List: TPouchItems;
    /// <summary>
    ///   Adds a page. If the address is already on the list, refreshes its title
    ///   instead of creating a duplicate.
    /// </summary>
    function Save(const Url, Title: string): TSaveResult;
    /// <summary>Changes the address and title; raises when the address is invalid or already on the list.</summary>
    function Update(const Id, Url, Title: string): TPouchItem;
    procedure Remove(const Id: string);
    procedure Restore(const Id: string);

    // Sync backend — used by Pouch.Sync.
    function Pending: TPouchItems;
    procedure MarkSynced(const Sent: TArray<TSyncStamp>);
    procedure ApplyRemote(const Remote: TPouchItems);
    function GetSyncState: TSyncState;
    procedure SetCursor(const Cursor: Int64);
    procedure SetSyncResult(const LastSyncAt: Int64; const LastError: string);
    procedure ResetSync;

    function GetSettings: TPouchSettings;
    procedure SetSettings(const Settings: TPouchSettings);
  end;

function NowMs: Int64;
function NewId: string;
/// <summary>Checks and normalizes a page address; raises on anything but http(s).</summary>
function NormalizeUrl(const Raw: string): string;
function TryNormalizeUrl(const Raw: string; out Url: string): Boolean;

implementation

uses
  System.IOUtils,
  System.DateUtils;

const
  ItemsKey = 'items';
  SyncKey = 'sync';
  SettingsKey = 'settings';

function NowMs: Int64;
begin
  Result := MilliSecondsBetween(TTimeZone.Local.ToUniversalTime(Now), UnixDateDelta);
end;

function NewId: string;
begin
  // TGUID.ToString gives "{XXXXXXXX-...}"; the server and the add-on use bare lowercase.
  Result := LowerCase(TGUID.NewGuid.ToString).Substring(1, 36);
end;

function TryNormalizeUrl(const Raw: string; out Url: string): Boolean;
var
  Text: string;
  SchemeEnd: Integer;
  Scheme: string;
  Rest: string;
  HostEnd: Integer;
  Host: string;
  Tail: string;
  I: Integer;
begin
  Result := False;
  Url := '';
  Text := Raw.Trim;
  SchemeEnd := Text.IndexOf('://');
  if SchemeEnd <= 0 then
    Exit;
  Scheme := Text.Substring(0, SchemeEnd).ToLower;
  if (Scheme <> 'http') and (Scheme <> 'https') then
    Exit;
  Rest := Text.Substring(SchemeEnd + 3);

  HostEnd := Rest.Length;
  for I := 0 to Rest.Length - 1 do
    if CharInSet(Rest.Chars[I], ['/', '?', '#']) then
    begin
      HostEnd := I;
      Break;
    end;
  Host := Rest.Substring(0, HostEnd);
  Tail := Rest.Substring(HostEnd);
  if (Host = '') or (Host.IndexOfAny([' ', #9, #10, #13]) >= 0) then
    Exit;

  // Same shape as URL.href in the browser: lowercase host, "/" as the empty path.
  if not Tail.StartsWith('/') then
    Tail := '/' + Tail;
  Url := Scheme + '://' + Host.ToLower + Tail;
  Result := True;
end;

function NormalizeUrl(const Raw: string): string;
begin
  if not TryNormalizeUrl(Raw, Result) then
    raise Exception.Create('Only http and https addresses can be saved.');
end;

function CleanTitle(const Raw, Url: string): string;
begin
  Result := Raw.Trim;
  if Result = '' then
    Result := Url;
end;

function CleanFavicon(const Raw: string): string;
var
  Lower: string;
begin
  Lower := Raw.ToLower;
  if Lower.StartsWith('http:') or Lower.StartsWith('https:') or Lower.StartsWith('data:image/') then
    Result := Raw
  else
    Result := '';
end;

{ TPouchItem }

function TPouchItem.IsDeleted: Boolean;
begin
  Result := DeletedAt <> 0;
end;

function TPouchItem.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', Id);
  Result.AddPair('url', Url);
  Result.AddPair('title', Title);
  Result.AddPair('favicon', Favicon);
  Result.AddPair('createdAt', TJSONNumber.Create(CreatedAt));
  Result.AddPair('updatedAt', TJSONNumber.Create(UpdatedAt));
  if DeletedAt <> 0 then
    Result.AddPair('deletedAt', TJSONNumber.Create(DeletedAt))
  else
    Result.AddPair('deletedAt', TJSONNull.Create);
end;

function JsonString(const Obj: TJSONObject; const Name: string): string;
var
  Value: TJSONValue;
begin
  Value := Obj.GetValue(Name);
  if Value is TJSONString then
    Result := TJSONString(Value).Value
  else
    Result := '';
end;

function JsonInt(const Obj: TJSONObject; const Name: string): Int64;
var
  Value: TJSONValue;
begin
  Value := Obj.GetValue(Name);
  if Value is TJSONNumber then
    Result := TJSONNumber(Value).AsInt64
  else
    Result := 0;
end;

class function TPouchItem.TryFromJson(const Value: TJSONValue; out Item: TPouchItem): Boolean;
var
  Obj: TJSONObject;
begin
  Result := False;
  Item := Default(TPouchItem);
  if not (Value is TJSONObject) then
    Exit;
  Obj := TJSONObject(Value);
  Item.Id := JsonString(Obj, 'id').ToLower;
  Item.Url := JsonString(Obj, 'url');
  Item.Title := JsonString(Obj, 'title');
  Item.Favicon := CleanFavicon(JsonString(Obj, 'favicon'));
  Item.CreatedAt := JsonInt(Obj, 'createdAt');
  Item.UpdatedAt := JsonInt(Obj, 'updatedAt');
  Item.DeletedAt := JsonInt(Obj, 'deletedAt');
  Item.Dirty := Obj.GetValue('dirty') is TJSONTrue;
  Result := (Item.Id.Length = 36) and (Item.Url <> '') and (Item.CreatedAt > 0) and (Item.UpdatedAt > 0);
end;

{ TPouchStore }

constructor TPouchStore.Create(const FileName: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TList<TPouchItem>.Create;
  FFileName := FileName;
  Load;
end;

destructor TPouchStore.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

procedure TPouchStore.Load;
var
  Root: TJSONValue;
  Items: TJSONArray;
  Element: TJSONValue;
  Item: TPouchItem;
  Section: TJSONObject;
begin
  FItems.Clear;
  FSyncState := Default(TSyncState);
  FSettings := Default(TPouchSettings);
  if not TFile.Exists(FFileName) then
    Exit;

  Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(FFileName, TEncoding.UTF8));
  try
    if not (Root is TJSONObject) then
      Exit;

    if TJSONObject(Root).GetValue(ItemsKey) is TJSONArray then
    begin
      Items := TJSONArray(TJSONObject(Root).GetValue(ItemsKey));
      for Element in Items do
        if TPouchItem.TryFromJson(Element, Item) then
          FItems.Add(Item);
    end;

    if TJSONObject(Root).GetValue(SyncKey) is TJSONObject then
    begin
      Section := TJSONObject(TJSONObject(Root).GetValue(SyncKey));
      FSyncState.Cursor := JsonInt(Section, 'cursor');
      FSyncState.LastSyncAt := JsonInt(Section, 'lastSyncAt');
      FSyncState.LastError := JsonString(Section, 'lastError');
    end;

    if TJSONObject(Root).GetValue(SettingsKey) is TJSONObject then
    begin
      Section := TJSONObject(TJSONObject(Root).GetValue(SettingsKey));
      FSettings.ServerUrl := JsonString(Section, 'serverUrl');
      FSettings.Token := JsonString(Section, 'token');
    end;
  finally
    Root.Free;
  end;
end;

procedure TPouchStore.Persist;
var
  Root: TJSONObject;
  Items: TJSONArray;
  Item: TPouchItem;
  Entry: TJSONObject;
  Section: TJSONObject;
  TempName: string;
begin
  Root := TJSONObject.Create;
  try
    Items := TJSONArray.Create;
    Root.AddPair(ItemsKey, Items);
    for Item in FItems do
    begin
      Entry := Item.ToJson;
      Entry.AddPair('dirty', TJSONBool.Create(Item.Dirty));
      Items.AddElement(Entry);
    end;

    Section := TJSONObject.Create;
    Root.AddPair(SyncKey, Section);
    Section.AddPair('cursor', TJSONNumber.Create(FSyncState.Cursor));
    Section.AddPair('lastSyncAt', TJSONNumber.Create(FSyncState.LastSyncAt));
    Section.AddPair('lastError', FSyncState.LastError);

    Section := TJSONObject.Create;
    Root.AddPair(SettingsKey, Section);
    Section.AddPair('serverUrl', FSettings.ServerUrl);
    Section.AddPair('token', FSettings.Token);

    // Write to a temporary file and swap, so a crash never leaves half a file.
    TempName := FFileName + '.tmp';
    TFile.WriteAllText(TempName, Root.ToJSON, TEncoding.UTF8);
    if TFile.Exists(FFileName) then
      TFile.Delete(FFileName);
    TFile.Move(TempName, FFileName);
  finally
    Root.Free;
  end;
end;

function TPouchStore.IndexOfId(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Id = Id then
      Exit(I);
  Result := -1;
end;

function TPouchStore.IndexOfUrl(const Url: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Url = Url then
      Exit(I);
  Result := -1;
end;

class procedure TPouchStore.Touch(var Item: TPouchItem);
begin
  Item.UpdatedAt := NowMs;
  Item.Dirty := True;
end;

function TPouchStore.List: TPouchItems;
var
  Active: TList<TPouchItem>;
  Item: TPouchItem;
begin
  FLock.Enter;
  try
    Active := TList<TPouchItem>.Create;
    try
      for Item in FItems do
        if not Item.IsDeleted then
          Active.Add(Item);
      Active.Sort(TComparer<TPouchItem>.Construct(
        function(const Left, Right: TPouchItem): Integer
        begin
          if Left.CreatedAt > Right.CreatedAt then
            Result := -1
          else if Left.CreatedAt < Right.CreatedAt then
            Result := 1
          else
            Result := 0;
        end));
      Result := Active.ToArray;
    finally
      Active.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TPouchStore.Save(const Url, Title: string): TSaveResult;
var
  Href: string;
  Index: Integer;
  Item: TPouchItem;
  Stamp: Int64;
begin
  Href := NormalizeUrl(Url);
  FLock.Enter;
  try
    Stamp := NowMs;
    Index := IndexOfUrl(Href);
    if Index >= 0 then
    begin
      Item := FItems[Index];
      Result.Existed := not Item.IsDeleted;
      if Title.Trim <> '' then
        Item.Title := CleanTitle(Title, Href);
      if Item.IsDeleted then
      begin
        Item.DeletedAt := 0;
        Item.CreatedAt := Stamp;
      end;
      Touch(Item);
      FItems[Index] := Item;
    end
    else
    begin
      Result.Existed := False;
      Item := Default(TPouchItem);
      Item.Id := NewId;
      Item.Url := Href;
      Item.Title := CleanTitle(Title, Href);
      Item.CreatedAt := Stamp;
      Touch(Item);
      FItems.Add(Item);
    end;
    Persist;
    Result.Item := Item;
  finally
    FLock.Leave;
  end;
end;

function TPouchStore.Update(const Id, Url, Title: string): TPouchItem;
var
  Href: string;
  Index: Integer;
  I: Integer;
begin
  Href := NormalizeUrl(Url);
  FLock.Enter;
  try
    Index := IndexOfId(Id);
    if Index < 0 then
      raise Exception.Create('Item not found.');
    for I := 0 to FItems.Count - 1 do
      if (I <> Index) and not FItems[I].IsDeleted and (FItems[I].Url = Href) then
        raise Exception.Create('This address is already on the list.');

    Result := FItems[Index];
    if Href <> Result.Url then
      Result.Favicon := '';
    Result.Url := Href;
    Result.Title := CleanTitle(Title, Href);
    Touch(Result);
    FItems[Index] := Result;
    Persist;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.Remove(const Id: string);
var
  Index: Integer;
  Item: TPouchItem;
begin
  FLock.Enter;
  try
    Index := IndexOfId(Id);
    if Index < 0 then
      raise Exception.Create('Item not found.');
    Item := FItems[Index];
    Item.DeletedAt := NowMs;
    Touch(Item);
    FItems[Index] := Item;
    Persist;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.Restore(const Id: string);
var
  Index: Integer;
  Item: TPouchItem;
begin
  FLock.Enter;
  try
    Index := IndexOfId(Id);
    if Index < 0 then
      raise Exception.Create('Item not found.');
    Item := FItems[Index];
    Item.DeletedAt := 0;
    Touch(Item);
    FItems[Index] := Item;
    Persist;
  finally
    FLock.Leave;
  end;
end;

function TPouchStore.Pending: TPouchItems;
var
  Dirty: TList<TPouchItem>;
  Item: TPouchItem;
begin
  FLock.Enter;
  try
    Dirty := TList<TPouchItem>.Create;
    try
      for Item in FItems do
        if Item.Dirty then
          Dirty.Add(Item);
      Result := Dirty.ToArray;
    finally
      Dirty.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.MarkSynced(const Sent: TArray<TSyncStamp>);
var
  Stamps: TDictionary<string, Int64>;
  Stamp: TSyncStamp;
  SentAt: Int64;
  I: Integer;
  Item: TPouchItem;
begin
  FLock.Enter;
  try
    Stamps := TDictionary<string, Int64>.Create;
    try
      for Stamp in Sent do
        Stamps.AddOrSetValue(Stamp.Id, Stamp.UpdatedAt);

      // A record changed while being sent (different UpdatedAt) stays dirty.
      // Sent tombstones are removed for good.
      for I := FItems.Count - 1 downto 0 do
      begin
        Item := FItems[I];
        if not Stamps.TryGetValue(Item.Id, SentAt) or (SentAt <> Item.UpdatedAt) then
          Continue;
        if Item.IsDeleted then
          FItems.Delete(I)
        else
        begin
          Item.Dirty := False;
          FItems[I] := Item;
        end;
      end;
    finally
      Stamps.Free;
    end;
    Persist;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.ApplyRemote(const Remote: TPouchItems);
var
  Incoming: TPouchItem;
  Index: Integer;
  Keepers: TDictionary<string, Integer>;
  I: Integer;
  KeeperIndex: Integer;
  Item: TPouchItem;
  Keeper: TPouchItem;
  ItemWins: Boolean;
  LoserIndex: Integer;
  Loser: TPouchItem;
begin
  FLock.Enter;
  try
    // For each id the newer UpdatedAt wins.
    for Incoming in Remote do
    begin
      Index := IndexOfId(Incoming.Id);
      if (Index >= 0) and (FItems[Index].UpdatedAt >= Incoming.UpdatedAt) then
        Continue;
      if (Index < 0) and Incoming.IsDeleted then
        Continue;
      Item := Incoming;
      Item.Dirty := False;
      if Index >= 0 then
        FItems[Index] := Item
      else
        FItems.Add(Item);
    end;

    // The same page saved independently on two devices has two different ids.
    // The older entry is kept (on a tie, the one with the smaller id), so every device
    // picks the same one; the others are deleted and that deletion goes to the server.
    Keepers := TDictionary<string, Integer>.Create;
    try
      for I := 0 to FItems.Count - 1 do
      begin
        Item := FItems[I];
        if Item.IsDeleted then
          Continue;
        if not Keepers.TryGetValue(Item.Url, KeeperIndex) then
        begin
          Keepers.Add(Item.Url, I);
          Continue;
        end;
        Keeper := FItems[KeeperIndex];
        ItemWins := (Item.CreatedAt < Keeper.CreatedAt)
          or ((Item.CreatedAt = Keeper.CreatedAt) and (CompareStr(Item.Id, Keeper.Id) < 0));
        if ItemWins then
        begin
          LoserIndex := KeeperIndex;
          Keepers[Item.Url] := I;
        end
        else
          LoserIndex := I;
        Loser := FItems[LoserIndex];
        Loser.DeletedAt := NowMs;
        Touch(Loser);
        FItems[LoserIndex] := Loser;
      end;
    finally
      Keepers.Free;
    end;

    for I := FItems.Count - 1 downto 0 do
      if FItems[I].IsDeleted and not FItems[I].Dirty then
        FItems.Delete(I);

    Persist;
  finally
    FLock.Leave;
  end;
end;

function TPouchStore.GetSyncState: TSyncState;
begin
  FLock.Enter;
  try
    Result := FSyncState;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.SetCursor(const Cursor: Int64);
begin
  FLock.Enter;
  try
    FSyncState.Cursor := Cursor;
    Persist;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.SetSyncResult(const LastSyncAt: Int64; const LastError: string);
begin
  FLock.Enter;
  try
    if LastSyncAt <> 0 then
      FSyncState.LastSyncAt := LastSyncAt;
    FSyncState.LastError := LastError;
    Persist;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.ResetSync;
var
  I: Integer;
  Item: TPouchItem;
begin
  // Prepares data for the first sync with a (new) server:
  // everything is queued for sending and pulling starts from the beginning.
  FLock.Enter;
  try
    for I := 0 to FItems.Count - 1 do
    begin
      Item := FItems[I];
      Item.Dirty := True;
      FItems[I] := Item;
    end;
    FSyncState := Default(TSyncState);
    Persist;
  finally
    FLock.Leave;
  end;
end;

function TPouchStore.GetSettings: TPouchSettings;
begin
  FLock.Enter;
  try
    Result := FSettings;
  finally
    FLock.Leave;
  end;
end;

procedure TPouchStore.SetSettings(const Settings: TPouchSettings);
begin
  FLock.Enter;
  try
    FSettings := Settings;
    Persist;
  finally
    FLock.Leave;
  end;
end;

end.
