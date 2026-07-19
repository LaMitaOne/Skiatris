# Skiatris
RADStudio FMX / Skia4Delphi Arcade Game "Skiatris". A high-performance, thread-safe falling block game prototype built entirely with Skia4Delphi.  

<img width="382" height="703" alt="Unbenannt" src="https://github.com/user-attachments/assets/c7727485-0956-41ef-abc2-ad070368d871" />

    
🎮 Gameplay Features


     Classic Mechanics: All 7 standard Tetromino pieces with proper rotation states.
     Wall Kicks: Smart rotation logic allows pieces to shift automatically if they hit a wall or block while rotating, just like in modern Tetris.
     Ghost Piece: A semi-transparent outline shows exactly where your piece will land.
     Neon Visuals: Pure vector rendering with heavy use of TSkMaskFilter for glowing blocks, grid lines, and UI text.
     Particle Explosions: Clearing lines triggers a satisfying burst of colored particles affected by gravity.
     Progressive Difficulty: The game speed increases every 10 cleared lines.
     Threaded Engine: Physics and input handling run on a background thread, synchronized safely with the main rendering thread for buttery-smooth 60 FPS.

🕹️ Controls

     Move Left/Right: A/D or Left/Right Arrows
     Soft Drop: S or Down Arrow
     Rotate: Spacebar
     Pause Menu: Escape

🛠️ Technical Details

     Renderer: Pure Skia Canvas (No Game Engine, no FMX shapes, no PNGs). Everything is mathematically drawn using paths, masks, and shaders.
     Threading: The game loop runs in an anonymous background thread. Inputs are collected thread-safely using a TCriticalSection and consumed immediately to prevent OS key-repeat spam.
     Data Structures: Uses a custom TBlocks array type to allow direct copy assignments (:=) of rotation states, avoiding messy nested loops.
     Rotation Normalization: The 4x4 rotation matrix is normalized (shifted to top-left) after rotating to prevent pieces from jumping unpredictably in the grid.

📦 What's Inside

     Skiatris.pas: The complete falling-block arcade engine in a single, highly commented file.
     Sample project and executable included.

🚀 Getting Started

    Open the project in RAD Studio (Delphi).
    Ensure you have the Skia4Delphi library installed.
    Run and play!

License

MIT License - Do whatever you want with it. Credits appreciated but not required.
