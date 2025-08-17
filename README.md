# NexBoot

NexBoot is a capable bootloader designed for the NeetComputers platform.
Its primary role is to initialize the system environment and load an operating system (OS) selected by the user or specified by configuration. NexBoot is engineered for simplicity, making it straightforward for developers to integrate their own operating systems into the Nex ecosystem.

## Usage

NexBoot currently supports system booting from the main system storage. Once disks for NeetComputers is released, additional disk booting capabilities will be available.

To run NexBoot on a computer, simply copy `bios.lua`, `ibm.bdf`, `rectcache.lua` (optional but HIGHLY reccomended), and `serpent.lua` to your `bios` partition.

To make your operating system bootable via NexBoot, you must provide a metadata file in the form of a Lua table. This file should be located at either:

```
system:boot/meta.lua
```

or

```
boot:meta.lua
```

### Metadata File Structure

The metadata file informs NexBoot of the essential details required to identify and launch your OS.
An example is shown below:

```lua
{
    name = "KairOS", -- Display name of your operating system
    version = "0.1.0", -- Current version identifier
    entrypoint = "system:core/kernel/kernel.lua" -- Primary script executed during boot
}
```

**Field Explanations**:

* **name**: Human-readable name that appears in NexBoot’s OS selection menu.
* **version**: Version string for display and diagnostic purposes.
* **entrypoint**: Path to the Lua script that serves as the OS kernel or main loader; this is executed when the OS is selected for boot.

### Example Appearance

When properly configured, the metadata file produces an entry in NexBoot’s menu, as shown below:
<img width="399" height="27" alt="image" src="https://github.com/user-attachments/assets/5bf84d18-5111-426e-b212-a8c7a5f5f35e" />

## APIs

NexBoot currently provides 5 functions in the global table:

`NexB.writeScr(str)`: Writes to the screen. Wraps

`NexB.flush()`: Flushes the text queue to the screen

`NexB.setCursorPos(x, y)`: Sets the cursor's position

`NexB.getCursorPos()`: Returns the x and y cursor position

`NexB.getInput()`: Gets user input

---

## Contact

* GitHub: `https://github.com/RedSoftware-US/NexBoot`
* Discord: `red.software`
* Email: `redsoftware-us@proton.me`

## License

NexBoot is released under the Apache License 2.0.
