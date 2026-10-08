#!/usr/bin/env python3
"""Builds the Shulker OS test scene on a running OC2 dev server through RCON (see README.md):

  computer A (0 -59 0): stock Sedna drive, network card, connector -> cable -> connector -> Internet Gateway
  computer B (-2 -59 0): the data pack's preloaded "Shulker OS" drive
  both powered by creative energy blocks behind them

    python3 scene.py [--player Dev]
"""
import argparse
import time

from rcon import cmd

FLASH = '{Slot:0b,id:"oc2:flash_memory",count:1,components:{"minecraft:custom_data":{oc2:{image:"oc2:block_devices/flash/riscv.bin"}}}}'


def computer_nbt(image, card=True):
    hdd = '{Slot:0b,id:"oc2:hard_drive_large",count:1,components:{"minecraft:custom_data":{oc2:{image:"%s"}}}}' % image
    cards = '{Slot:0b,id:"oc2:network_interface_card",count:1}' if card else ""
    return ('items:{"oc2:cpu":{Size:1,Items:[{Slot:0b,id:"oc2:cpu_riscv",count:1}]},'
            '"oc2:memory":{Size:4,Items:[{Slot:0b,id:"oc2:memory_large",count:1},{Slot:1b,id:"oc2:memory_large",count:1}]},'
            '"oc2:hard_drive":{Size:4,Items:[%s]},"oc2:flash_memory":{Size:1,Items:[%s]},'
            '"oc2:card":{Size:4,Items:[%s]}}' % (hdd, FLASH, cards))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--player", default="Dev")
    a = ap.parse_args()
    steps = [
        "forceload add -16 -16 16 16",
        "fill -4 -60 -1 4 -60 2 minecraft:stone",
        "setblock 0 -59 0 oc2:computer[facing=north]{%s}" % computer_nbt("oc2:block_devices/hdd/sedna.bin"),
        "setblock 0 -59 1 oc2:creative_energy",
        "setblock 3 -59 0 oc2:internet_gateway[facing=north]",
        "setblock 3 -59 1 oc2:creative_energy",
        "setblock 1 -59 0 oc2:network_connector[face=wall,facing=east]",
        "setblock 2 -59 0 oc2:network_connector[face=wall,facing=west]",
        # cables are links between connectors; set them once both ends exist
        "data merge block 2 -59 0 {connections:[{position:[I;1,-59,0]}]}",
        "data merge block 1 -59 0 {connections:[{position:[I;2,-59,0],is_owner:1b}]}",
        "setblock -2 -59 0 oc2:computer[facing=north]{%s}" % computer_nbt("shulkeros:block_devices/hdd/shulkeros.bin", card=False),
        "setblock -2 -59 1 oc2:creative_energy",
        "setworldspawn 0 -59 -3",
        "op " + a.player,
        "tp %s 0.5 -59 -2.5 facing 0.5 -58.6 0.5" % a.player,
    ]
    for s in steps:
        print(">", s[:100])
        print(" ", cmd(s))
        time.sleep(0.3)


if __name__ == "__main__":
    main()
