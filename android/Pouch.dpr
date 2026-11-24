program Pouch;

uses
  System.StartUpCopy,
  FMX.Forms,
  Pouch.Store in 'Pouch.Store.pas',
  Pouch.Sync in 'Pouch.Sync.pas',
  Pouch.Platform in 'Pouch.Platform.pas',
  Pouch.Main in 'Pouch.Main.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
