obj-m+=dht22_driver.o
dht22_driver-objs+=dht22.o dht22_sm.o

all: compile

compile:
	make C=2 -C /lib/modules/$(shell uname -r)/build/ M=$(PWD) modules

install:
	make -C /lib/modules/$(shell uname -r)/build/ M=$(PWD) modules_install
	depmod -A

clean:
	make -C /lib/modules/$(shell uname -r)/build/ M=$(PWD) clean
