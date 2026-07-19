{*******************************************************************************
  Skiatris (Neon Arcade Edition)
********************************************************************************
  A high-performance, thread-safe falling block game built on Skia4Delphi.
  Classic gameplay with full neon glow, ghost pieces, and particle explosions.

  Controls:
  - Move: A/D or Arrow Left/Right
  - Soft Drop: S or Arrow Down
  - Rotate: Spacebar

  Author:  Lara Miriam Tamy Reschke
  License: MIT
*******************************************************************************}

unit uSkiatris;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, System.Skia;

const
  COLS = 10;
  ROWS = 20;
  TILE_SIZE = 32;
  FALL_TIME = 0.5; // Base seconds per cell drop

type
  TGameState = (gsPlaying, gsPaused, gsGameOver);
  TPieceType = (ptI, ptJ, ptL, ptO, ptS, ptT, ptZ);

  // Custom type for block matrices allows direct assignment (:=)
  // between variables, which standard anonymous arrays do not.
  TBlocks = array[0..3, 0..3] of Boolean;

  // Represents a Tetromino piece
  TPiece = record
    X, Y: Integer;
    Type_: TPieceType;
    Rotation: Integer;
    Blocks: TBlocks;
    Color: TAlphaColor;
  end;

  // Visual particle for explosions and effects
  TParticle = record
    Pos: TPointF;
    Vel: TPointF;
    Life: Single;
    Color: TAlphaColor;
    Size: Single;
  end;

  TSkiatrisGame = class(TSkCustomControl)
  private
    { Threading & Timing }
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection;

    { Input }
    FKeys: set of Byte;

    { Game State }
    FGameState: TGameState;
    FGrid: array[0..COLS-1, 0..ROWS-1] of TAlphaColor;
    FCurrentPiece: TPiece;
    FNextPiece: TPiece;
    FScore: Integer;
    FLines: Integer;
    FLevel: Integer;
    FFallTimer: Single;

    { Visual Effects }
    FParticles: TList<TParticle>;
    FFlashTimer: Single;
    FLinesToClear: TList<Integer>;

    { Core Methods }
    procedure InitPiece(var Piece: TPiece; PType: TPieceType);
    procedure NewPiece;
    procedure RotatePiece;
    function CheckCollision(X, Y: Integer; const Blocks: TBlocks): Boolean;
    procedure MergePiece;
    procedure ClearLines;
    procedure SpawnLineParticles(Y: Integer);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;

    { Rendering Routines }
    procedure DrawBlock(const ACanvas: ISkCanvas; X, Y: Integer; Color: TAlphaColor; Alpha: Byte = 255; IsGhost: Boolean = False);
    procedure DrawGrid(const ACanvas: ISkCanvas);
    procedure DrawGhostPiece(const ACanvas: ISkCanvas);
    procedure DrawPiece(const ACanvas: ISkCanvas; const Piece: TPiece);
    procedure DrawParticles(const ACanvas: ISkCanvas);
    procedure DrawUI(const ACanvas: ISkCanvas);
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
  end;

implementation

{ =============================================================================
  PIECE INITIALIZATION
============================================================================= }
procedure TSkiatrisGame.InitPiece(var Piece: TPiece; PType: TPieceType);
begin
  Piece.Type_ := PType;
  Piece.Rotation := 0;
  Piece.X := 3;
  Piece.Y := 0;

  // Clear matrix
  for var Y := 0 to 3 do
    for var X := 0 to 3 do
      Piece.Blocks[X, Y] := False;

  // Define base shapes (Top-Left aligned to simplify rotation logic)
  case PType of
    ptI: begin Piece.Color := $FF00FFFF; Piece.Blocks[0, 1] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; Piece.Blocks[3, 1] := True; end;
    ptJ: begin Piece.Color := $FF0000FF; Piece.Blocks[0, 0] := True; Piece.Blocks[0, 1] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; end;
    ptL: begin Piece.Color := $FFFF8800; Piece.Blocks[2, 0] := True; Piece.Blocks[0, 1] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; end;
    ptO: begin Piece.Color := $FFFFFF00; Piece.Blocks[1, 0] := True; Piece.Blocks[2, 0] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; end;
    ptS: begin Piece.Color := $FF00FF00; Piece.Blocks[1, 0] := True; Piece.Blocks[2, 0] := True; Piece.Blocks[0, 1] := True; Piece.Blocks[1, 1] := True; end;
    ptT: begin Piece.Color := $FFFF00FF; Piece.Blocks[1, 0] := True; Piece.Blocks[0, 1] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; end;
    ptZ: begin Piece.Color := $FFFF0000; Piece.Blocks[0, 0] := True; Piece.Blocks[1, 0] := True; Piece.Blocks[1, 1] := True; Piece.Blocks[2, 1] := True; end;
  end;
end;

procedure TSkiatrisGame.NewPiece;
var
  PType: TPieceType;
begin
  FCurrentPiece := FNextPiece;
  PType := TPieceType(Random(7));
  InitPiece(FNextPiece, PType);

  // If the new piece collides immediately, game is over
  if CheckCollision(FCurrentPiece.X, FCurrentPiece.Y, FCurrentPiece.Blocks) then
    FGameState := gsGameOver;
end;

{ =============================================================================
  GAME LOGIC & COLLISION
============================================================================= }
procedure TSkiatrisGame.RotatePiece;
var
  TempBlocks, NormalizedBlocks: TBlocks;
  X, Y, Kick, MinX, MinY: Integer;
  FoundBlock: Boolean;
begin
  // 1. Rotate matrix clockwise into TempBlocks
  for Y := 0 to 3 do
    for X := 0 to 3 do
      TempBlocks[3 - Y, X] := FCurrentPiece.Blocks[X, Y];

  // 2. Normalize matrix (shift piece to Top-Left)
  // This prevents pieces from jumping around inside the 4x4 grid after rotating.
  for Y := 0 to 3 do
    for X := 0 to 3 do
      NormalizedBlocks[X, Y] := False;

  // Find first used row (MinY)
  MinY := 4;
  for Y := 0 to 3 do
  begin
    FoundBlock := False;
    for X := 0 to 3 do
      if TempBlocks[X, Y] then FoundBlock := True;
    if FoundBlock then begin MinY := Y; Break; end;
  end;

  // Find first used col (MinX)
  MinX := 4;
  for X := 0 to 3 do
  begin
    FoundBlock := False;
    for Y := 0 to 3 do
      if TempBlocks[X, Y] then FoundBlock := True;
    if FoundBlock then begin MinX := X; Break; end;
  end;

  // Apply shift
  if (MinX < 4) and (MinY < 4) then
  begin
    for Y := 0 to 3 do
      for X := 0 to 3 do
        if (X + MinX <= 3) and (Y + MinY <= 3) then
          NormalizedBlocks[X, Y] := TempBlocks[X + MinX, Y + MinY]
        else
          NormalizedBlocks[X, Y] := False;
  end;

  // 3. Attempt rotation with Wall-Kicks (0, -1, -2, +1, +2)
  // Allows rotating pieces even when pressed flat against a wall.
  for Kick := 0 to 2 do
  begin
    if not CheckCollision(FCurrentPiece.X - Kick, FCurrentPiece.Y, NormalizedBlocks) then
    begin
      FCurrentPiece.X := FCurrentPiece.X - Kick;
      FCurrentPiece.Blocks := NormalizedBlocks;
      Exit;
    end;
    if (Kick > 0) and not CheckCollision(FCurrentPiece.X + Kick, FCurrentPiece.Y, NormalizedBlocks) then
    begin
      FCurrentPiece.X := FCurrentPiece.X + Kick;
      FCurrentPiece.Blocks := NormalizedBlocks;
      Exit;
    end;
  end;

  // If all attempts fail, rotation is cancelled silently.
end;

function TSkiatrisGame.CheckCollision(X, Y: Integer; const Blocks: TBlocks): Boolean;
var
  BX, BY: Integer;
begin
  Result := False;
  for BY := 0 to 3 do
  begin
    for BX := 0 to 3 do
    begin
      if Blocks[BX, BY] then
      begin
        // Check map boundaries
        if (X + BX < 0) or (X + BX >= COLS) or (Y + BY >= ROWS) then
          Exit(True);
        // Check collision with settled blocks in the grid
        if (Y + BY >= 0) and (FGrid[X + BX, Y + BY] <> TAlphaColors.Null) then
          Exit(True);
      end;
    end;
  end;
end;

procedure TSkiatrisGame.MergePiece;
var
  BX, BY, GridX, GridY: Integer;
begin
  // Transfer the active piece's blocks into the static grid array
  for BY := 0 to 3 do
  begin
    for BX := 0 to 3 do
    begin
      if FCurrentPiece.Blocks[BX, BY] then
      begin
        GridX := FCurrentPiece.X + BX;
        GridY := FCurrentPiece.Y + BY;
        // Safety bounds check before writing to array
        if (GridX >= 0) and (GridX < COLS) and (GridY >= 0) and (GridY < ROWS) then
          FGrid[GridX, GridY] := FCurrentPiece.Color;
      end;
    end;
  end;
end;

procedure TSkiatrisGame.SpawnLineParticles(Y: Integer);
var
  X: Integer;
  P: TParticle;
begin
  // Emit explosion particles for every cell in the cleared line
  for X := 0 to COLS - 1 do
  begin
    P.Pos := PointF(X * TILE_SIZE + TILE_SIZE / 2, Y * TILE_SIZE + TILE_SIZE / 2);
    P.Vel := PointF((Random - 0.5) * 600, (Random - 0.5) * 600 - 200);
    P.Life := 1.0;
    P.Color := FGrid[X, Y];
    P.Size := 6 + Random * 6;
    FParticles.Add(P);
  end;
end;

procedure TSkiatrisGame.ClearLines;
var
  Y, X: Integer;
  LineFull: Boolean;
begin
  FLinesToClear.Clear;
  Y := ROWS - 1;

  // Scan from bottom to top
  while Y >= 0 do
  begin
    LineFull := True;
    for X := 0 to COLS - 1 do
      if FGrid[X, Y] = TAlphaColors.Null then
      begin
        LineFull := False;
        Break;
      end;

    if LineFull then
    begin
      FLinesToClear.Add(Y);
      SpawnLineParticles(Y);
      Dec(Y);
    end
    else
      Dec(Y);
  end;

  // If lines were found, trigger flash effect and update score
  if FLinesToClear.Count > 0 then
  begin
    FFlashTimer := 0.3;
    Inc(FLines, FLinesToClear.Count);
    Inc(FScore, (100 * FLevel) * FLinesToClear.Count);
    if FLines mod 10 = 0 then
      Inc(FLevel);
  end;
end;

{ =============================================================================
  PHYSICS & INPUT UPDATE LOOP
============================================================================= }
procedure TSkiatrisGame.DoPhysicsUpdate(DeltaSec: Double);
var
  Left, Right, Down, Rotate: Boolean;
  X, NewY, I: Integer;
  P: TParticle;
begin
  if not FActive then Exit;
  if FGameState <> gsPlaying then Exit;

  // Update Particles (apply gravity, decrease life)
  for I := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[I];
    P.Pos := P.Pos + TPointF.Create(P.Vel.X * DeltaSec, P.Vel.Y * DeltaSec);
    P.Vel.Y := P.Vel.Y + 800 * DeltaSec;
    P.Life := P.Life - DeltaSec;
    if P.Life <= 0 then
      FParticles.Delete(I)
    else
      FParticles[I] := P;
  end;

  // Handle Line Clearing delay
  if FFlashTimer > 0 then
  begin
    FFlashTimer := FFlashTimer - DeltaSec;
    if FFlashTimer <= 0 then
    begin
      // Physically shift grid down for each cleared line
      for var LineY in FLinesToClear do
      begin
        for NewY := LineY downto 1 do
          for X := 0 to COLS - 1 do
            FGrid[X, NewY] := FGrid[X, NewY - 1];
        for X := 0 to COLS - 1 do
          FGrid[X, 0] := TAlphaColors.Null;
      end;
      FLinesToClear.Clear;
      NewPiece;
    end;
    Exit; // Pause block falling while lines are flashing
  end;

  // Read Inputs Thread-Safely
  FLock.Acquire;
  try
    Left := (Byte(vkLeft) in FKeys) or (Byte(Ord('A')) in FKeys);
    Right := (Byte(vkRight) in FKeys) or (Byte(Ord('D')) in FKeys);
    Down := (Byte(vkDown) in FKeys) or (Byte(Ord('S')) in FKeys);
    Rotate := (Byte(vkSpace) in FKeys);
  finally
    FLock.Release;
  end;

  // Consume Inputs immediately to prevent OS key-repeat spam
  if Rotate then
  begin
    RotatePiece;
    FLock.Acquire;
    try Exclude(FKeys, Byte(vkSpace)); finally FLock.Release; end;
  end;

  if Left then
  begin
    if not CheckCollision(FCurrentPiece.X - 1, FCurrentPiece.Y, FCurrentPiece.Blocks) then
      FCurrentPiece.X := FCurrentPiece.X - 1;
    FLock.Acquire;
    try
      Exclude(FKeys, Byte(vkLeft));
      Exclude(FKeys, Byte(Ord('A')));
    finally FLock.Release; end;
  end;

  if Right then
  begin
    if not CheckCollision(FCurrentPiece.X + 1, FCurrentPiece.Y, FCurrentPiece.Blocks) then
      FCurrentPiece.X := FCurrentPiece.X + 1;
    FLock.Acquire;
    try
      Exclude(FKeys, Byte(vkRight));
      Exclude(FKeys, Byte(Ord('D')));
    finally FLock.Release; end;
  end;

  // Gravity Logic
  if Down then
    FFallTimer := FFallTimer + DeltaSec * 10 // Soft drop speeds up fall
  else
    FFallTimer := FFallTimer + DeltaSec;

  if FFallTimer >= (FALL_TIME / FLevel) then
  begin
    FFallTimer := 0;
    if not CheckCollision(FCurrentPiece.X, FCurrentPiece.Y + 1, FCurrentPiece.Blocks) then
    begin
      FCurrentPiece.Y := FCurrentPiece.Y + 1;
    end
    else
    begin
      // Piece has landed
      MergePiece;
      ClearLines;
      if FFlashTimer <= 0 then
        NewPiece;
    end;
  end;
end;

{ =============================================================================
  RENDERING ROUTINES
============================================================================= }
procedure TSkiatrisGame.DrawBlock(const ACanvas: ISkCanvas; X, Y: Integer; Color: TAlphaColor; Alpha: Byte = 255; IsGhost: Boolean = False);
var
  Rect: TRectF;
  Paint, GlowPaint: ISkPaint;
  C: TAlphaColor;
begin
  Rect := TRectF.Create(X * TILE_SIZE, Y * TILE_SIZE, (X + 1) * TILE_SIZE, (Y + 1) * TILE_SIZE);
  C := Color;
  TAlphaColorRec(C).A := Alpha;

  if IsGhost then
  begin
    // Ghost pieces are drawn as transparent outlines
    Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
    Paint.StrokeWidth := 2;
    Paint.AntiAlias := True;
    Paint.Color := C;
    Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 4.0);
    ACanvas.DrawRoundRect(Rect, 4, 4, Paint);
  end
  else
  begin
    // Massive Neon Glow layer
    GlowPaint := TSkPaint.Create(TSkPaintStyle.Fill);
    GlowPaint.AntiAlias := True;
    GlowPaint.Color := C;
    GlowPaint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 10.0);
    ACanvas.DrawRoundRect(Rect, 4, 4, GlowPaint);

    // Solid Core Block
    Paint := TSkPaint.Create(TSkPaintStyle.Fill);
    Paint.AntiAlias := True;
    Paint.Color := C;
    ACanvas.DrawRoundRect(Rect, 4, 4, Paint);

    // Inner Highlight (gives a 3D bevel effect)
    Paint.Color := $FFFFFFFF;
    Paint.Alpha := 60;
    ACanvas.DrawRoundRect(TRectF.Create(Rect.Left+4, Rect.Top+4, Rect.Right-4, Rect.Bottom-4), 2, 2, Paint);
  end;
end;

procedure TSkiatrisGame.DrawGrid(const ACanvas: ISkCanvas);
var
  X, Y: Integer;
  Paint, BgPaint: ISkPaint;
  IsFlashing: Boolean;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  // Render Dark Neon Gradient Background
  BgPaint := TSkPaint.Create;
  BgPaint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, ROWS * TILE_SIZE),
    TArray<TAlphaColor>.Create($FF050510, $FF11051f), nil, TSkTileMode.Clamp);
  ACanvas.DrawPaint(BgPaint);
  BgPaint.Shader := nil;

  // Render Glowing Grid Lines
  Paint.Color := $FF2a2a4e;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 1;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 1.0);

  for X := 0 to COLS do
    ACanvas.DrawLine(PointF(X * TILE_SIZE, 0), PointF(X * TILE_SIZE, ROWS * TILE_SIZE), Paint);
  for Y := 0 to ROWS do
    ACanvas.DrawLine(PointF(0, Y * TILE_SIZE), PointF(COLS * TILE_SIZE, Y * TILE_SIZE), Paint);

  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := nil;

  // Draw settled blocks
  IsFlashing := FFlashTimer > 0;
  for Y := 0 to ROWS - 1 do
  begin
    for X := 0 to COLS - 1 do
    begin
      if FGrid[X, Y] <> TAlphaColors.Null then
      begin
        if IsFlashing and FLinesToClear.Contains(Y) then
          // Flash bright cyan instead of blinding white to preserve background visibility
          DrawBlock(ACanvas, X, Y, $FF00FFFF)
        else
          DrawBlock(ACanvas, X, Y, FGrid[X, Y]);
      end;
    end;
  end;
end;

procedure TSkiatrisGame.DrawGhostPiece(const ACanvas: ISkCanvas);
var
  GhostY, X, Y: Integer;
  Rect: TRectF;
  Paint: ISkPaint;
  GhostColor: TAlphaColor;
begin
  // Calculate lowest valid Y position
  GhostY := FCurrentPiece.Y;
  while not CheckCollision(FCurrentPiece.X, GhostY + 1, FCurrentPiece.Blocks) do
    Inc(GhostY);

  GhostColor := FCurrentPiece.Color;
  TAlphaColorRec(GhostColor).A := 120; // Semi-transparent

  Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
  Paint.StrokeWidth := 2;
  Paint.AntiAlias := True;
  Paint.Color := GhostColor;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);

  // Draw outline at calculated position
  for Y := 0 to 3 do
  begin
    for X := 0 to 3 do
    begin
      if FCurrentPiece.Blocks[X, Y] then
      begin
        Rect := TRectF.Create(
          (FCurrentPiece.X + X) * TILE_SIZE,
          (GhostY + Y) * TILE_SIZE,
          (FCurrentPiece.X + X + 1) * TILE_SIZE,
          (GhostY + Y + 1) * TILE_SIZE
        );
        ACanvas.DrawRoundRect(Rect, 4, 4, Paint);
      end;
    end;
  end;
end;

procedure TSkiatrisGame.DrawPiece(const ACanvas: ISkCanvas; const Piece: TPiece);
var
  X, Y: Integer;
begin
  for Y := 0 to 3 do
    for X := 0 to 3 do
      if Piece.Blocks[X, Y] then
        DrawBlock(ACanvas, Piece.X + X, Piece.Y + Y, Piece.Color);
end;

procedure TSkiatrisGame.DrawParticles(const ACanvas: ISkCanvas);
var
  P: TParticle;
  Paint: ISkPaint;
begin
  if FParticles.Count = 0 then Exit;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 5.0);

  for P in FParticles do
  begin
    Paint.Color := P.Color;
    Paint.Alpha := Round(P.Life * 255);
    if Paint.Alpha > 255 then Paint.Alpha := 255;
    ACanvas.DrawCircle(P.Pos, P.Size * P.Life, Paint);
  end;
end;

procedure TSkiatrisGame.DrawUI(const ACanvas: ISkCanvas);
var
  Font: TSkFont;
  Paint: ISkPaint;
  Txt: string;
begin
  Txt := 'Score: ' + IntToStr(FScore) + ' | Lines: ' + IntToStr(FLines) + ' | Level: ' + IntToStr(FLevel);
  Font := TSkFont.Create;
  try
    Paint := TSkPaint.Create;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.AntiAlias := True;

    // Text Glow
    Paint.Color := TAlphaColors.Cyan;
    Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 4.0);
    ACanvas.DrawSimpleText(Txt, 10, 40, Font, Paint);

    // Core Text
    Paint.MaskFilter := nil;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText(Txt, 10, 40, Font, Paint);
  finally
    Font.Free;
  end;
end;

procedure TSkiatrisGame.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  // Thread-safe rendering block
  FLock.Acquire;
  try
    DrawGrid(ACanvas);
    if (FGameState = gsPlaying) and (FFlashTimer <= 0) then
    begin
      DrawGhostPiece(ACanvas);
      DrawPiece(ACanvas, FCurrentPiece);
    end;
    DrawParticles(ACanvas);
  finally
    FLock.Release;
  end;

  DrawUI(ACanvas);
end;

{ =============================================================================
  LIFECYCLE & THREADING
============================================================================= }
procedure TSkiatrisGame.SafeInvalidate;
begin
  if csDestroying in ComponentState then Exit;
  // Queue redraw safely on the main UI thread
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
      begin
        Redraw;
        Repaint;
      end;
    end);
end;

procedure TSkiatrisGame.StartThread;
begin
  if Assigned(FThread) then Exit;
  // Run physics loop in anonymous thread to keep UI responsive
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then DeltaMS := 1;
        LastTime := NowTime;
        if FActive then
        begin
          DoPhysicsUpdate(DeltaMS / 1000);
          SafeInvalidate;
        end;
        Sleep(16); // Cap at roughly 60 FPS
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkiatrisGame.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50);
  end;
end;

constructor TSkiatrisGame.Create(AOwner: TComponent);
var
  X, Y: Integer;
  PType: TPieceType;
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  Align := TAlignLayout.Client;
  HitTest := True;
  CanFocus := True;
  TabStop := True;

  FActive := True;
  FGameState := gsPlaying;
  FScore := 0;
  FLines := 0;
  FLevel := 1;
  FFallTimer := 0;

  FParticles := TList<TParticle>.Create;
  FLinesToClear := TList<Integer>.Create;
  FFlashTimer := 0;

  // Initialize empty grid
  for X := 0 to COLS - 1 do
    for Y := 0 to ROWS - 1 do
      FGrid[X, Y] := TAlphaColors.Null;

  // Initialize first pieces
  PType := TPieceType(Random(7));
  InitPiece(FCurrentPiece, PType);
  PType := TPieceType(Random(7));
  InitPiece(FNextPiece, PType);

  StartThread;
end;

destructor TSkiatrisGame.Destroy;
begin
  StopThread;
  FreeAndNil(FLock);
  FreeAndNil(FParticles);
  FreeAndNil(FLinesToClear);
  inherited;
end;

{ =============================================================================
  INPUT HANDLING
============================================================================= }
procedure TSkiatrisGame.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  GameKey: Byte;
begin
  if Key = vkEscape then
  begin
    if FGameState = gsPlaying then FGameState := gsPaused
    else if FGameState = gsPaused then FGameState := gsPlaying;
    Exit;
  end;

  if FGameState <> gsPlaying then Exit;

  GameKey := 0;
  // Check virtual keys for arrows and space
  case Key of
    vkLeft, vkDown, vkRight, vkSpace: GameKey := Key;
  end;

  // If virtual key didn't match, check character keys for WASD and Space
  if GameKey = 0 then
  begin
    case KeyChar of
      'A', 'a': GameKey := Ord('A');
      'S', 's': GameKey := Ord('S');
      'D', 'd': GameKey := Ord('D');
      ' ':      GameKey := vkSpace;
    end;
  end;

  if GameKey > 0 then
  begin
    FLock.Acquire;
    try Include(FKeys, GameKey); finally FLock.Release; end;
    Key := 0;
    KeyChar := #0;
  end;
  inherited;
end;

procedure TSkiatrisGame.KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  GameKey: Byte;
begin
  GameKey := 0;
  case Key of
    vkLeft, vkDown, vkRight, vkSpace: GameKey := Key;
  end;

  // CRITICAL: Also check KeyChar on KeyUp to properly catch Spacebar release
  if GameKey = 0 then
  begin
    case KeyChar of
      'A', 'a': GameKey := Ord('A');
      'S', 's': GameKey := Ord('S');
      'D', 'd': GameKey := Ord('D');
      ' ':      GameKey := vkSpace;
    end;
  end;

  if GameKey > 0 then
  begin
    FLock.Acquire;
    try Exclude(FKeys, GameKey); finally FLock.Release; end;
    Key := 0;
    KeyChar := #0;
  end;
  inherited;
end;

end.
