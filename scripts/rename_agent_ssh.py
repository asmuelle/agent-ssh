import os

root_dir = "/Users/andreasmuller/experiments/appstore/apps/agent-ssh"

replacements = [
    ("McSshMacOS", "AgentSshMacOS"),
    ("McSshApp", "AgentSshApp"),
    ("McSsh", "AgentSsh"),
    ("mcSsh", "agentSsh"),
    ("midnight-ssh", "agent-ssh"),
]

ignored_dirs = {".git", "target", ".derivedData", "Agent-Ssh.xcodeproj"}
valid_extensions = {".swift", ".yml", ".plist", ".toml", ".md", ".json", ".modulemap", ".sh"}
valid_names = {"justfile", "build.rs"}

for dirpath, dirnames, filenames in os.walk(root_dir):
    # filter out ignored directories in-place
    dirnames[:] = [d for d in dirnames if d not in ignored_dirs]
    
    for filename in filenames:
        ext = os.path.splitext(filename)[1]
        if ext in valid_extensions or filename in valid_names:
            filepath = os.path.join(dirpath, filename)
            try:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                
                new_content = content
                modified = False
                for old, new in replacements:
                    if old in new_content:
                        new_content = new_content.replace(old, new)
                        modified = True
                
                if modified:
                    with open(filepath, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    print(f"Renamed content in: {filepath}")
            except Exception as e:
                print(f"Error processing {filepath}: {e}")
