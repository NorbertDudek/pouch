unit Pouch.Platform;

// Platform glue: opening a page in the default browser and receiving pages
// shared to the app ("Share → Pouch" in the browser, Intent.ACTION_SEND).
// On Windows the app runs too (handy for debugging), only without sharing.

interface

uses
  System.SysUtils,
  System.Messaging;

type
  TSharedPage = record
    Url: string;
    Title: string;
  end;

  TShareHandler = reference to procedure(const Text, Subject: string);

  /// <summary>
  ///   Delivers shared text both when the app is started by a share and when
  ///   it is already running (singleTask activity → onNewIntent).
  /// </summary>
  TShareReceiver = class
  private
    FHandler: TShareHandler;
    FSubscription: TMessageSubscriptionId;
    FLastText: string;
    FLastAt: TDateTime;
    procedure ActivityMessage(const Sender: TObject; const M: TMessage);
    procedure Deliver(const Text, Subject: string);
  public
    constructor Create(const Handler: TShareHandler);
    destructor Destroy; override;
    /// <summary>Call when the app becomes active: picks up the intent it was started with.</summary>
    procedure CheckPending;
  end;

/// <summary>Opens the address in the default browser; raises when there is none.</summary>
procedure OpenInBrowser(const Url: string);

/// <summary>
///   Finds the first http(s) address in shared text. The title is the subject or,
///   without one, the rest of the text (some apps send "Title https://…").
/// </summary>
function ParseSharedText(const Text, Subject: string; out Page: TSharedPage): Boolean;

implementation

uses
  System.RegularExpressions,
  System.DateUtils
{$IFDEF ANDROID}
  ,
  Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNI.App,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Net,
  Androidapi.Helpers,
  FMX.Platform.Android
{$ENDIF}
{$IFDEF MSWINDOWS}
  ,
  Winapi.Windows,
  Winapi.ShellAPI
{$ENDIF}
  ;

procedure OpenInBrowser(const Url: string);
{$IFDEF ANDROID}
var
  Intent: JIntent;
begin
  Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_VIEW, StrToJURI(Url));
  Intent.addCategory(TJIntent.JavaClass.CATEGORY_BROWSABLE);
  TAndroidHelper.Activity.startActivity(Intent);
end;
{$ELSEIF DEFINED(MSWINDOWS)}
begin
  if ShellExecute(0, 'open', PChar(Url), nil, nil, SW_SHOWNORMAL) <= 32 then
    raise Exception.Create('Cannot open the browser.');
end;
{$ELSE}
begin
  raise Exception.Create('Opening pages is not supported on this platform.');
end;
{$ENDIF}

function ParseSharedText(const Text, Subject: string; out Page: TSharedPage): Boolean;
const
  TitleSeparators: array[0..5] of Char = (' ', '-', #$2013, #$2014, ':', '|');
var
  Match: TMatch;
  Url: string;
  Rest: string;
begin
  Page := Default(TSharedPage);
  Match := TRegEx.Match(Text, 'https?://[^\s<>"]+', [roIgnoreCase]);
  if not Match.Success then
    Exit(False);

  // Trailing punctuation from a sentence is not part of the address.
  Url := Match.Value;
  while (Url <> '') and CharInSet(Url[High(Url)], ['.', ',', ';', ':', '!', '?', ')', ']', '''']) do
    Delete(Url, High(Url), 1);

  Page.Url := Url;
  Page.Title := Subject.Trim;
  if Page.Title = '' then
  begin
    Rest := (Text.Substring(0, Match.Index - 1) + ' ' + Text.Substring(Match.Index - 1 + Match.Length)).Trim;
    Rest := TRegEx.Replace(Rest, '\s+', ' ');
    // Many apps append a "via …" or a dash before the link.
    Rest := Rest.Trim(TitleSeparators);
    Page.Title := Rest;
  end;
  Result := True;
end;

{ TShareReceiver }

constructor TShareReceiver.Create(const Handler: TShareHandler);
begin
  inherited Create;
  FHandler := Handler;
{$IFDEF ANDROID}
  MainActivity.registerIntentAction(TJIntent.JavaClass.ACTION_SEND);
  FSubscription := TMessageManager.DefaultManager.SubscribeToMessage(
    TMessageReceivedNotification, ActivityMessage);
{$ENDIF}
end;

destructor TShareReceiver.Destroy;
begin
{$IFDEF ANDROID}
  TMessageManager.DefaultManager.Unsubscribe(TMessageReceivedNotification, FSubscription);
{$ENDIF}
  inherited;
end;

{$IFDEF ANDROID}
procedure HandleIntent(const Intent: JIntent; const Deliver: TShareHandler);
var
  Text: string;
  Subject: string;
begin
  if (Intent = nil) or not TJIntent.JavaClass.ACTION_SEND.equals(Intent.getAction) then
    Exit;
  Text := JStringToString(Intent.getStringExtra(TJIntent.JavaClass.EXTRA_TEXT));
  Subject := JStringToString(Intent.getStringExtra(TJIntent.JavaClass.EXTRA_SUBJECT));
  // Handled once: an intent left in place would be saved again on every return to the app.
  MainActivity.setIntent(TJIntent.JavaClass.init);
  Deliver(Text, Subject);
end;
{$ENDIF}

procedure TShareReceiver.ActivityMessage(const Sender: TObject; const M: TMessage);
begin
{$IFDEF ANDROID}
  if M is TMessageReceivedNotification then
    HandleIntent(TMessageReceivedNotification(M).Value, Deliver);
{$ENDIF}
end;

procedure TShareReceiver.CheckPending;
begin
{$IFDEF ANDROID}
  HandleIntent(MainActivity.getIntent, Deliver);
{$ENDIF}
end;

procedure TShareReceiver.Deliver(const Text, Subject: string);
begin
  // The same share can arrive twice: as a new intent and as the activity's intent.
  if (Text = FLastText) and (SecondsBetween(Now, FLastAt) < 5) then
    Exit;
  FLastText := Text;
  FLastAt := Now;
  FHandler(Text, Subject);
end;

end.
