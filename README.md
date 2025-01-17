# DHT22 Sensor Driver

The DHT22 is a basic temperature and humidity sensor. Learn more from the links
below:
* Sensor overview from [Adafruit](https://learn.adafruit.com/dht/overview)
* Datasheet for
[DHT22](https://www.sparkfun.com/datasheets/Sensors/Temperature/DHT22.pdf)

This driver is compiled and tested on Raspberry Pi 3 Model B running Raspbian
(Linux raspberrypi 4.4.38-v7+ #938). The sensor is connected to the Pi via a
breadboard.

This driver uses the Linux kernel GPIO API to trigger the sensor, and processes
the data received by calculating the time intervals between interrupts (a
transition from HIGH to LOW or from LOW to HIGH state).

## Contents

 1. [General Overview](#general-overview)  
   1.1. [Triggering The Sensor](#triggering-the-sensor)  
   1.2. [Reading The Data](#reading-the-data)  
   1.3. [Interpreting The Data](#interpreting-the-data)  
 2. [Using The Driver](#using-the-driver)  
   2.1. [Loading/Unloading The Driver](#loadingunloading-the-driver)  
   2.2. [Installing The Driver](#installing-the-driver)  
   2.3. [Sysfs Attributes](#sysfs-attributes)  
 3. [Implementation Details](#implementation-details)  
   3.1. [GPIO API](#gpio-api)  
   3.2. [IRQ API](#irq-api)  
   3.3. [Sysfs Attributes Creation](#sysfs-attributes-creation)  
   3.4. [High-resolution Timers](#high-resolution-timers)  
   3.5. [FSM](#fsm)  
   3.6. [Interrupt Handling](#interrupt-handling)  
 4. [Performance Issues](#performance-issues)  

## General Overview  
[back to top](#dht22-sensor-driver)

### Triggering The Sensor  
[back to top](#dht22-sensor-driver)

The DHT22 must be manually triggered with a specific signal as follows:
 1. Line is initially kept HIGH (it is active when it is LOW). We must allow
sufficient time for the sensor to start up before sending the actual triggering
signal. In this driver, the interval is set to 100 ms; in popular libraries it
is about 250 ms.
 2. Pull the line LOW for at least 1 ms. In this driver, the triggering signal
is set to 10 ms (the **dht22.h** file contains a #define macro, refer to it as
some adjustments may be made). In other libraries, 20 ms is a popular choice.
 3. Stop pulling LOW, allowing the line to return to HIGH and wait between 20
and 40 us. This driver waits 40 us.

The DHT22 sensor is relatively slow and can be read once every two seconds at
most.

### Reading The Data  
[back to top](#dht22-sensor-driver)

The DHT22 produces a total of 83 interrupts on the line which are interpreted as
5 bytes of data - two bytes containing the humidity reading, two bytes
containing the temperature reading, and a hash which is the sum of the other
four bytes.

The sensor starts by sending two preliminary signals, each ~80 us in length - it
first pulls the line LOW, then releases it back to HIGH.

Data is sent bit by bit, a total of 40 bits (5 bytes). For each bit, there are
two signals - one preparatory (50 us LOW) and one containing the actual bit
value. The bit value is signalled by a HIGH signal, the length of the signal
determines whether it is '0' or '1' - a '0' is about 28 us and a '1' is about 70
us. As a convenient simplification, the signal length can be compared to 50 us,
which is the preparatory signal length; a '0' will surely be shorter than 50 us
and a '1' will surely be longer.

### Interpreting The Data  
[back to top](#dht22-sensor-driver)

Both the humidity and temperature take 2 bytes of data. Most significant bits
are received first. The most sigificant temperature bit shows the sign as the
sensor can read negative temperatures as well (this will be bit 7 of byte 2).
Converting the two bytes (for both humidity and temperature) to a 16 bit number
produces the actual result multiplied by 10, e.g. a temperature of 25.2 degress
Celsius will be represented as the number 252, or in binary: 00000000 11111100.

## Using The Driver  
[back to top](#dht22-sensor-driver)

### Loading/Unloading The Driver  
[back to top](#dht22-sensor-driver)

The git repository contains the compiled .ko file which can be dynamically
loaded in the kernel with the following command (as root):

`insmod dht22_driver.ko [gpio=<gpio>] [autoupdate=<true,false>]
[autoupdate_timeout=<timeout>]`

The `gpio` parameter determines on which gpio the sensor is connected (per the
[BCM scheme](https://pinout.xyz/#)). It defaults to 6.

The `autoupdate` parameter determines whether the sensor will be automatically
re-triggered at a predefined interval (2 seconds minimum, which is also the
default). Anything different from '0' is interpreted as `true`. Note that the
sensor is triggered at least once (on module load).

The `autoupdate_timeout` parameter can be used to modify the default timeout,
minimum is 2 seconds, maximum is 10 minutes. Values are in milliseconds. This
only has effect if `autoupdate` is `true`.

The driver can be unloaded by executing (as root): `rmmod dht22_driver`.

The driver can be recompiled using `make`.

### Installing The Driver
[back to top](#dht22-sensor-driver)

The module can now be also permanently installed and loaded during bootup.
1. recompile the driver using `make compile`
2. install the driver using `sudo make install`
3. add `dht22_driver` to `/etc/modules`
4. create `/etc/modprobe.d/dht22_driver.conf` file
5. add `options dht22_driver gpio=<gpio> autoupdate=1 autoupdate_timeout=<milliseconds>`
   to the file (note the `gpio` parameter must reflect to which pin the sensor is connected
6. run `sudo update-initramfs -c -k $(uname -r)`
7. reboot
8. check if the module has been successfully loaded `lsmod | grep -i dht22`

### Sysfs Attributes  
[back to top](#dht22-sensor-driver)

When loaded, the driver creates a directory in _/sys/kernel/_ called 'dht22'.
The following attributes are exported:
* **temperature** (read-only) - shows the most recent temperature reading, in
Celsius, e.g. '16.5'
* **humidity** (read-only) - shows the most recent humidity reading in percent,
e.g. '14.2%'
* **gpio_number** (read-only) - shows the gpio on which the sensor is connected.
This is read-only since changing the circuit while the Raspberry is on is highly
discouraged. The gpio can only be set on module load time.
* **autoupdate** (read-write) - shows or changes the autoupdate setting. Writing
anything other than 0 is interpreted as `true`.
* **autoupdate\_timeout\_ms** (read-write) - shows or changes the interval
between triggering events. It only has effect if `autoupdate` is set to `true`.
* **trigger** (write-only) - writing anything other than 0 to this file will
cause a triggering event if `autoupdate` is set to `false` or if sufficient time
has passed since the previous reading.

Note that writing to files in _/sys/kernel/_ is forbidden for group 'other',
therefore any writes should be performed with root permissions. This is enforced
by the kernel, not by the driver.

## Implementation Details  
[back to top](#dht22-sensor-driver)

### GPIO API  
[back to top](#dht22-sensor-driver)

The driver makes use of the kernel's GPIO API in order to use the sensor.
First, the provided GPIO is checked for validity with a call to
`gpio_is_valid()`.

When this succeeds, the GPIO is requested with `gpio_request()`.

Direction is changed when needed with `gpio_direction_input()` and
`gpio_direction_output()`. Initially, it is set in input mode (also necessary
in order to setup the IRQ). When triggerring, direction is changed to output
and afterwards returned to input.

The GPIO is exported to sysfs via `gpio_export()`; this creates the directory
_/sys/class/gpio/gpioNum/_.

On error and module unload time cleanup is performed via `gpio_unexport()` and
`gpio_free()`.

### IRQ API  
[back to top](#dht22-sensor-driver)

In order to read data from the sensor, the driver processes interrupts from the
specified GPIO. First, the IRQ number is obtained via `gpio_to_irq()`, then
it is requested by `request_irq()`. Here, it is specified that the driver needs
to know when the level changes (either from LOW to HIGH or vice versa).

An interrupt handler is installed which calculates the amount of time which has
passed from the previous interrupt and stores the result (in microseconds) to a
static array; then, a work is queued to change and handle the state machine's
state (more on the FSM [below](#fsm)).

Cleanup is performed via `free_irq()`.

### Sysfs Attributes Creation  
[back to top](#dht22-sensor-driver)

Two functions are used in order to export the necessary sysfs attributes
described above in the section [Sysfs Attributes](#sysfs-attributes).

`kobject_create_and_add()` creates a kobject with the kernel kobject as parent;
this puts the sysfs directory for the driver in _/sys/kernel/_.

`sysfs_create_group()` does the rest using previously defined attributes with
load and/or store handlers for each attribute (file).

Cleanup is performed via `kobject_put()`.

### High-resolution Timers  
[back to top](#dht22-sensor-driver)

Two timers are used by the driver.

The first is responsible for triggering the
sensor repeatedly when `autoupdate` is `true`. It expires every
`autoupdate_interval` milliseconds and runs a handler which triggers the sensor.
It checks each time whether `autoupdate` is still `true` and recalculates the
next expiration using `autoupdate_interval` since both values can be modified
dynamically via sysfs (as described eariler).

The second timer only runs if `autoupdate` is `false` and the previous sensor
reading failed. It re-triggers the sensor (up to 5 times) in order to obtain
a valid reading.

### FSM  
[back to top](#dht22-sensor-driver)

A finite state machine is implemented to keep track of the current state. It can
be in one of the following states: IDLE, RESPONDING, FINISHED, ERROR.

Each state has an associated `get_next_state()` and `handle_state()` function.
Several flags are used to determine the course of action; these flags are set
primarily by the interrupt handling routine, e.g. when the expected 86 IRQs are
handled, the `finished` flag is set, causing the machine to transition from
RESPONDING to FINISHED.

State transitions and handling happen in the bottom half since function call
overhead causes significant delay in the IRQ handler (which is unacceptable
given the strict time constraints when working with the DHT22 sensor).

All FSM-related definitions are separated in **dht22\_sm.h** and
**dht22\_sm.c**.

### Interrupt Handling  
[back to top](#dht22-sensor-driver)

The interrupt handling routine is only responsible for acknowledging the IRQ,
calculating the time passed since the previous IRQ (storing the result in a
static array), raising `finished` or `error` flags in the state machine, and
queueing the FSM state transition and handling.

## Performance Issues  
[back to top](#dht22-sensor-driver)

There are noticeable performance issues when the system is under heavier load.
This is easier to notice when the `autoupdate` option is set to `true` and
the update interval is left at its default (also minimum) value of 2 seconds.

There are two kinds of errors that can be observed - hash mismatches and missed
interrupts. Both can be traced back to latencies, usually connected with the
USB (as expected) or hrtimers.

`ftrace` reveals that when multiple interrupts occur the time between IRQs
coming from the DHT22 becomes irregular and sometimes ambiguous (e.g. is a
value signal of 52 us a "1" or a "0"?). Examples of both 0s that are longer than
50 us and 1s shorter than 50 us were found.

A possible approach to solve this is to use a FIQ. From
[BCM2835 ARM Peripherals](https://www.raspberrypi.org/wp-content/uploads/2012/02/BCM2835-ARM-Peripherals.pdf#page=110):

> 7.3 Fast Interrupt (FIQ).  
> One interrupt sources can be selected to be connected to the ARM FIQ input.
> There is also one FIQ enable. An interrupt which is selected as FIQ should
> have its normal interrupt enable bit cleared.
>
> 7.4    Interrupt priority.  
> There is no priority for any interrupt. If one interrupt is much more
> important then all others it can be routed to the FIQ.

However, writing a FIQ handler is somewhat involved. First, the USB FIQ must be
disabled since only one FIQ can be enabled (per Broadcom's document). Second,
a FIQ handler must only use the range of registers R8-R14; this condition is
impossible to enforce when compiling with gcc, therefore the handler itself
must be written in assembly.

A FIQ seems to be the only way to ensure the driver consistently reads the
sensor data correctly. However, there are mechanisms which ensure that the
driver recovers from errors and the performace problems are not too pronounced
to justify the time and effort required to imeplement a FIQ.


[back to top](#dht22-sensor-driver)
