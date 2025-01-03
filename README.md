# ZulkanZengine

## Getting started

### Install the Vulkan SDK

You must install the LunarG Vulkan SDK: https://vulkan.lunarg.com/sdk/home

### Clone the repository and dependencies

```sh
git clone 

cd ZulkanZengine
```

### Ensure glslc is on your PATH

On MacOS, you may e.g. place the following in your `~/.zprofile` file:

```sh
export PATH=$PATH:$HOME/VulkanSDK/1.3.xxx.0/macOS/bin/
```

### Run the example

```sh
zig build run
```

