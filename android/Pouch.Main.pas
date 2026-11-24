unit Pouch.Main;

// The only screen of the app: the list of saved links and the sync settings.
//   tap an item          → open it in the default browser
//   Edit on an item      → change its title and address, or delete it
//   search box           → filter by title and address
//   swipe an item        → delete it
//   pull the list down   → sync now
//   Share → Pouch        → save the page (handled by TShareReceiver)

interface

uses
  System.SysUtils,
  System.Types,
  System.UITypes,
  System.Classes,
  System.Messaging,
  System.Threading,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,
  FMX.StdCtrls,
  FMX.Controls.Presentation,
  FMX.Edit,
  FMX.Layouts,
  FMX.TabControl,
  FMX.ListView.Types,
  FMX.ListView.Appearances,
  FMX.ListView.Adapters.Base,
  FMX.ListView,
  Pouch.Store,
  Pouch.Sync,
  Pouch.Platform;

type
  TMainForm = class(TForm)
    TabControl: TTabControl;
    TabList: TTabItem;
    ToolBarList: TToolBar;
    LabelTitle: TLabel;
    ButtonAdd: TSpeedButton;
    ButtonSettings: TSpeedButton;
    ButtonSync: TSpeedButton;
    ListView: TListView;
    LabelEmpty: TLabel;
    LabelStatus: TLabel;
    TabSettings: TTabItem;
    ToolBarSettings: TToolBar;
    LabelSettingsTitle: TLabel;
    ButtonBack: TSpeedButton;
    ScrollSettings: TVertScrollBox;
    LabelServer: TLabel;
    EditServer: TEdit;
    LabelToken: TLabel;
    EditToken: TEdit;
    ButtonSave: TButton;
    LabelSettingsInfo: TLabel;
    SyncTimer: TTimer;
    SearchEdit: TEdit;
    SearchClearButton: TClearEditButton;
    TabEdit: TTabItem;
    ToolBarEdit: TToolBar;
    LabelEditHeader: TLabel;
    ButtonEditBack: TSpeedButton;
    ScrollEdit: TVertScrollBox;
    LabelEditTitle: TLabel;
    EditTitle: TEdit;
    LabelEditUrl: TLabel;
    EditUrl: TEdit;
    ButtonEditSave: TButton;
    ButtonEditOpen: TButton;
    ButtonEditDelete: TButton;
    LabelEditInfo: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure ListViewItemClick(const Sender: TObject; const AItem: TListViewItem);
    procedure ListViewDeletingItem(Sender: TObject; AIndex: Integer; var ACanDelete: Boolean);
    procedure ListViewPullRefresh(Sender: TObject);
    procedure ButtonAddClick(Sender: TObject);
    procedure ButtonSettingsClick(Sender: TObject);
    procedure ButtonSyncClick(Sender: TObject);
    procedure ButtonBackClick(Sender: TObject);
    procedure ButtonSaveClick(Sender: TObject);
    procedure SyncTimerTimer(Sender: TObject);
    procedure ListViewButtonClick(const Sender: TObject; const AItem: TListItem;
      const AObject: TListItemSimpleControl);
    procedure SearchEditChangeTracking(Sender: TObject);
    procedure ButtonEditBackClick(Sender: TObject);
    procedure ButtonEditSaveClick(Sender: TObject);
    procedure ButtonEditOpenClick(Sender: TObject);
    procedure ButtonEditDeleteClick(Sender: TObject);
  private
    FStore: TPouchStore;
    FEditingId: string;
    FButtonClickedAt: UInt64;
    FShares: TShareReceiver;
    FAppEvents: TMessageSubscriptionId;
    FSyncing: Boolean;
    FSyncAgain: Boolean;
    procedure AppEvent(const Sender: TObject; const M: TMessage);
    procedure SharedText(const Text, Subject: string);
    procedure AddPage(const Url, Title: string);
    procedure RefreshList;
    procedure ShowStatus(const Text: string);
    procedure ShowSyncState;
    procedure ScheduleSync;
    procedure SyncNow;
    procedure SyncFinished(const Outcome: TSyncResult);
    procedure ShowSettings;
    procedure ShowList;
    procedure ShowEditor(const Id: string);
    procedure DeleteItem(const Id: string);
    function FindItem(const Id: string; out Item: TPouchItem): Boolean;
    function ClipboardText: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

uses
  System.IOUtils,
  System.DateUtils,
  FMX.Platform,
  FMX.DialogService.Async;

const
  DataFileName = 'pouch.json';

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FStore := TPouchStore.Create(TPath.Combine(TPath.GetDocumentsPath, DataFileName));

  ListView.ItemAppearance.ItemAppearance := 'ImageListItemBottomDetailRightButton';
  // A hidden image has zero width, so the text starts at the left edge.
  ListView.ItemAppearanceObjects.ItemObjects.Image.Visible := False;
  ListView.ItemAppearanceObjects.ItemObjects.TextButton.Text := 'Edit';
  ListView.ItemAppearanceObjects.ItemObjects.Text.Font.Size := 16;
  ListView.ItemAppearanceObjects.ItemObjects.Detail.Font.Size := 12;

  TabControl.TabPosition := TTabPosition.None;
  TabControl.ActiveTab := TabList;

  FShares := TShareReceiver.Create(SharedText);
  FAppEvents := TMessageManager.DefaultManager.SubscribeToMessage(TApplicationEventMessage, AppEvent);

  RefreshList;
  ShowSyncState;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  MainForm := nil;
  TMessageManager.DefaultManager.Unsubscribe(TApplicationEventMessage, FAppEvents);
  FShares.Free;
  // A running sync still uses the store; on exit the process takes it anyway.
  if not FSyncing then
    FStore.Free;
end;

procedure TMainForm.AppEvent(const Sender: TObject; const M: TMessage);
begin
  case TApplicationEventMessage(M).Value.Event of
    TApplicationEvent.BecameActive:
      begin
        FShares.CheckPending;
        SyncNow;
      end;
    TApplicationEvent.EnteredBackground:
      if (Length(FStore.Pending) > 0) and not FSyncing then
        SyncNow;
  end;
end;

procedure TMainForm.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  if (Key = vkHardwareBack) and (TabControl.ActiveTab <> TabList) then
  begin
    Key := 0;
    ShowList;
  end;
end;

{ List }

procedure TMainForm.RefreshList;
var
  Items: TPouchItems;
  Item: TPouchItem;
  Entry: TListViewItem;
  Query: string;
  Shown: Integer;
begin
  Items := FStore.List;
  Query := SearchEdit.Text.Trim.ToLower;
  Shown := 0;
  ListView.BeginUpdate;
  try
    ListView.Items.Clear;
    for Item in Items do
    begin
      // Search matches the title and the address, ignoring letter case.
      if (Query <> '') and not Item.Title.ToLower.Contains(Query)
        and not Item.Url.ToLower.Contains(Query) then
        Continue;
      Entry := ListView.Items.Add;
      Entry.Text := Item.Title;
      Entry.Detail := Item.Url;
      Entry.TagString := Item.Id;
      Inc(Shown);
    end;
  finally
    ListView.EndUpdate;
  end;

  if Length(Items) = 0 then
    LabelEmpty.Text := 'No saved links yet. In the browser choose Share ' + #$2192 + ' Pouch to save a page.'
  else
    LabelEmpty.Text := 'No links match the search.';
  LabelEmpty.Visible := Shown = 0;
end;

procedure TMainForm.SearchEditChangeTracking(Sender: TObject);
begin
  RefreshList;
end;

function TMainForm.FindItem(const Id: string; out Item: TPouchItem): Boolean;
var
  Candidate: TPouchItem;
begin
  for Candidate in FStore.List do
    if Candidate.Id = Id then
    begin
      Item := Candidate;
      Exit(True);
    end;
  Item := Default(TPouchItem);
  Result := False;
end;

procedure TMainForm.ListViewItemClick(const Sender: TObject; const AItem: TListViewItem);
var
  Url: string;
begin
  // A tap on the Edit button may also count as a tap on the item; the check runs
  // after both events, so the browser opens only for taps outside the button.
  Url := AItem.Detail;
  TThread.ForceQueue(nil,
    procedure
    begin
      if (MainForm = nil) or (TThread.GetTickCount64 - FButtonClickedAt < 600) then
        Exit;
      try
        OpenInBrowser(Url);
      except
        on E: Exception do
          ShowStatus('Cannot open the page: ' + E.Message);
      end;
    end);
end;

procedure TMainForm.ListViewButtonClick(const Sender: TObject; const AItem: TListItem;
  const AObject: TListItemSimpleControl);
begin
  FButtonClickedAt := TThread.GetTickCount64;
  ShowEditor(TListViewItem(AItem).TagString);
end;

procedure TMainForm.ListViewDeletingItem(Sender: TObject; AIndex: Integer; var ACanDelete: Boolean);
begin
  try
    FStore.Remove(ListView.Items[AIndex].TagString);
    ACanDelete := True;
    ShowStatus('Deleted.');
    ScheduleSync;
  except
    on E: Exception do
    begin
      ACanDelete := False;
      ShowStatus(E.Message);
    end;
  end;
end;

procedure TMainForm.ListViewPullRefresh(Sender: TObject);
begin
  SyncNow;
end;

procedure TMainForm.ButtonSyncClick(Sender: TObject);
begin
  SyncNow;
end;

{ Saving }

procedure TMainForm.SharedText(const Text, Subject: string);
var
  Page: TSharedPage;
begin
  ShowList;
  if ParseSharedText(Text, Subject, Page) then
    AddPage(Page.Url, Page.Title)
  else
    ShowStatus('No link found in the shared text.');
end;

procedure TMainForm.AddPage(const Url, Title: string);
var
  Saved: TSaveResult;
begin
  try
    Saved := FStore.Save(Url, Title);
  except
    on E: Exception do
    begin
      ShowStatus(E.Message);
      Exit;
    end;
  end;
  RefreshList;
  ListView.ScrollTo(0);
  if Saved.Existed then
    ShowStatus('Already on the list: ' + Saved.Item.Title)
  else
    ShowStatus('Saved: ' + Saved.Item.Title);
  ScheduleSync;
end;

function TMainForm.ClipboardText: string;
var
  Clipboard: IFMXClipboardService;
begin
  Result := '';
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Clipboard) then
    try
      Result := Clipboard.GetClipboard.ToString;
    except
      Result := '';
    end;
end;

procedure TMainForm.ButtonAddClick(Sender: TObject);
var
  Suggestion: TSharedPage;
  Initial: string;
begin
  // Suggest an address from the clipboard, the usual source of a link to add by hand.
  if ParseSharedText(ClipboardText, '', Suggestion) then
    Initial := Suggestion.Url
  else
    Initial := 'https://';

  TDialogServiceAsync.InputQuery('Add link', ['Address'], [Initial],
    procedure(const AResult: TModalResult; const AValues: array of string)
    var
      Page: TSharedPage;
    begin
      if AResult <> mrOk then
        Exit;
      if ParseSharedText(AValues[0], '', Page) then
        AddPage(Page.Url, Page.Title)
      else
        ShowStatus('Only http and https addresses can be saved.');
    end);
end;

{ Editing }

procedure TMainForm.ShowEditor(const Id: string);
var
  Item: TPouchItem;
begin
  if not FindItem(Id, Item) then
  begin
    ShowStatus('Item not found.');
    RefreshList;
    Exit;
  end;
  FEditingId := Item.Id;
  EditTitle.Text := Item.Title;
  EditUrl.Text := Item.Url;
  LabelEditInfo.Text := '';
  TabControl.SetActiveTabWithTransition(TabEdit, TTabTransition.Slide);
end;

procedure TMainForm.ButtonEditBackClick(Sender: TObject);
begin
  ShowList;
end;

procedure TMainForm.ButtonEditSaveClick(Sender: TObject);
var
  Item: TPouchItem;
begin
  try
    Item := FStore.Update(FEditingId, EditUrl.Text, EditTitle.Text);
  except
    on E: Exception do
    begin
      LabelEditInfo.Text := E.Message;
      Exit;
    end;
  end;
  RefreshList;
  ShowList;
  ShowStatus('Saved: ' + Item.Title);
  ScheduleSync;
end;

procedure TMainForm.ButtonEditOpenClick(Sender: TObject);
begin
  try
    OpenInBrowser(NormalizeUrl(EditUrl.Text));
  except
    on E: Exception do
      LabelEditInfo.Text := E.Message;
  end;
end;

procedure TMainForm.ButtonEditDeleteClick(Sender: TObject);
var
  Id: string;
begin
  Id := FEditingId;
  TDialogServiceAsync.MessageDialog('Delete this link?', TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0,
    procedure(const AResult: TModalResult)
    begin
      if AResult = mrYes then
        DeleteItem(Id);
    end);
end;

procedure TMainForm.DeleteItem(const Id: string);
begin
  try
    FStore.Remove(Id);
  except
    on E: Exception do
    begin
      LabelEditInfo.Text := E.Message;
      Exit;
    end;
  end;
  RefreshList;
  ShowList;
  ShowStatus('Deleted.');
  ScheduleSync;
end;

{ Sync }

procedure TMainForm.ShowStatus(const Text: string);
begin
  LabelStatus.Text := Text;
end;

procedure TMainForm.ShowSyncState;
var
  State: TSyncState;
begin
  State := FStore.GetSyncState;
  if FStore.GetSettings.ServerUrl = '' then
    ShowStatus('Stored on this device only — sync is off.')
  else if State.LastError <> '' then
    ShowStatus('Sync failed: ' + State.LastError)
  else if State.LastSyncAt <> 0 then
    ShowStatus('Synced ' + FormatDateTime('d mmm, hh:nn',
      UnixToDateTime(State.LastSyncAt div 1000, False)))
  else
    ShowStatus('Not synced yet.');
end;

procedure TMainForm.ScheduleSync;
begin
  // Several quick changes go out in one request.
  SyncTimer.Enabled := False;
  SyncTimer.Enabled := True;
end;

procedure TMainForm.SyncTimerTimer(Sender: TObject);
begin
  SyncNow;
end;

procedure TMainForm.SyncNow;
var
  Store: TPouchStore;
begin
  SyncTimer.Enabled := False;
  if FSyncing then
  begin
    FSyncAgain := True;
    Exit;
  end;
  if FStore.GetSettings.ServerUrl = '' then
    Exit;

  FSyncing := True;
  ButtonSync.Enabled := False;
  Store := FStore;
  TTask.Run(
    procedure
    var
      Outcome: TSyncResult;
    begin
      Outcome := TPouchSync.Run(Store);
      TThread.Queue(nil,
        procedure
        begin
          if MainForm <> nil then
            MainForm.SyncFinished(Outcome);
        end);
    end);
end;

procedure TMainForm.SyncFinished(const Outcome: TSyncResult);
begin
  FSyncing := False;
  ButtonSync.Enabled := True;
  if Outcome.Received then
    RefreshList;
  ShowSyncState;
  if FSyncAgain then
  begin
    FSyncAgain := False;
    SyncNow;
  end;
end;

{ Settings }

procedure TMainForm.ButtonSettingsClick(Sender: TObject);
begin
  ShowSettings;
end;

procedure TMainForm.ButtonBackClick(Sender: TObject);
begin
  ShowList;
end;

procedure TMainForm.ShowSettings;
var
  Settings: TPouchSettings;
begin
  Settings := FStore.GetSettings;
  EditServer.Text := Settings.ServerUrl;
  EditToken.Text := Settings.Token;
  LabelSettingsInfo.Text :=
    'The address of the folder where server/index.php from the Pouch repository is installed, ' +
    'and the token from its config.php. Leave the address empty to keep links on this device only.';
  TabControl.SetActiveTabWithTransition(TabSettings, TTabTransition.Slide);
end;

procedure TMainForm.ShowList;
begin
  if TabControl.ActiveTab <> TabList then
    TabControl.SetActiveTabWithTransition(TabList, TTabTransition.Slide, TTabTransitionDirection.Reversed);
end;

procedure TMainForm.ButtonSaveClick(Sender: TObject);
var
  Previous: TPouchSettings;
  Settings: TPouchSettings;
begin
  if FSyncing then
  begin
    LabelSettingsInfo.Text := 'Sync is running — try again in a moment.';
    Exit;
  end;

  try
    Settings.ServerUrl := NormalizeServerUrl(EditServer.Text);
  except
    on E: Exception do
    begin
      LabelSettingsInfo.Text := E.Message;
      Exit;
    end;
  end;
  Settings.Token := EditToken.Text.Trim;
  if (Settings.ServerUrl <> '') and (Settings.Token.Length < 16) then
  begin
    LabelSettingsInfo.Text := 'The token has at least 16 characters — copy it from config.php on the server.';
    Exit;
  end;

  Previous := FStore.GetSettings;
  FStore.SetSettings(Settings);
  // A new server starts from scratch: everything is sent and pulling starts from the beginning.
  if Settings.ServerUrl <> Previous.ServerUrl then
    FStore.ResetSync;

  ShowList;
  ShowSyncState;
  SyncNow;
end;

end.
