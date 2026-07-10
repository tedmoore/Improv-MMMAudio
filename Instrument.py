import copy
from datetime import datetime
from email import message
import re
import sys
from enum import Enum
from pathlib import Path
import threading

sys.path.insert(0, str(Path(__file__).parent.parent))

from mmm_audio.MLP_Python import train_new_mlp
from mmm_python import *
from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QSlider, QCheckBox, QTabWidget, QGroupBox, QFileDialog, QDoubleSpinBox, QGridLayout, QComboBox, QScrollArea, QMessageBox, QLineEdit
from PySide6.QtGui import QPalette, QColor
from PySide6.QtCore import QObject, QEvent, Qt, Signal

from typing import Protocol, Optional

import json
import argparse
import ControlsBridge
from supriya_midi import MidiIn, MidiOut, MidiMessage
import supriya_midi

SaveValue = dict | float | int | bool

class Saveable(Protocol):
    def save(self) -> SaveValue: ...
    def load(self, d: SaveValue): ...

class StateSaver:

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.saveable_items: dict = {}
        self._save_attrs: list = []

    def save(self) -> dict:
        d = {}
        for k, v in self.saveable_items.items():
            d[k] = v.save()
        for attr in self._save_attrs:
            d[attr] = getattr(self, attr)
        return d

    def load(self, d: dict, is_software_boot: bool = False):
        if d is not None:        
            for k, v in d.items():
                if k in self.saveable_items:
                    self.saveable_items[k].load(v, is_software_boot=is_software_boot)
                elif k in self._save_attrs:
                    setattr(self, k, v)

    def add_saveable_item(self, key: str, item: Saveable):
        self.saveable_items[key] = item

    def add_save_attr(self, *attr_names: str):
        self._save_attrs.extend(attr_names)

class QuNeoDataTypes(Enum):
    """Types of data that can come from the QuNeo."""
    NOTE = 2
    PRESSURE = 3
    X = 4
    Y = 5

class QuNeoModes(Enum):
    """Operating modes for the QuNeo manager."""
    PLAY = 0
    SET_PAD_MODES = 1
    NOTE = 2
    PRESSURE = 3
    X = 4
    Y = 5

class QuNeoPadModes(Enum):
    """Pad modes for the QuNeo."""
    ON_OFF = 0
    OFF_ON = 1
    ON = 2
    NOT_USED = 3

class QuNeoManager(StateSaver,Saveable):
    
    # Class-level constants
    PAD_CC_PARAMS = [QuNeoDataTypes.PRESSURE, QuNeoDataTypes.X, QuNeoDataTypes.Y]
    MODE_MAP = {
        16: QuNeoModes.NOTE,
        18: QuNeoModes.PRESSURE,
        20: QuNeoModes.X,
        22: QuNeoModes.Y,
        25: QuNeoModes.SET_PAD_MODES,
        26: QuNeoModes.PLAY,
    }
    
    def __init__(
        self,
        hid_manager: 'HIDManager',
        midi_output_names: Optional[list] = None,
    ):
        self.hid_manager = hid_manager
        self.mode = QuNeoModes.PLAY
        self.pad_modes = [QuNeoPadModes.NOT_USED] * 16  # Default pad modes
        self._init_midi_output(midi_output_names)
        self._update_pad_colors()
    
    def _init_midi_output(self, midi_output_names: Optional[list] = None):
        if midi_output_names and 'QUNEO' in midi_output_names:
            self.midi_out = MidiOut().open_port(midi_output_names.index('QUNEO'))
        else:
            self.midi_out = None
            print("\033[1;33mWarning: QUNEO MIDI output not found.\033[0m")

    def save(self) -> dict:
        """Save the current state for persistence."""
        list_of_strings = [pm.name for pm in self.pad_modes]
        return {'pad_modes': list_of_strings}
    
    def load(self, data: dict, is_software_boot: bool = False):
        self.pad_modes = [QuNeoPadModes[pm] for pm in data.get('pad_modes', [QuNeoPadModes.NOT_USED.name] * 16)]
        self._update_pad_colors()
    
    # ==================== MIDI Input Handlers ====================

    def note(self, channel_id: int, note: int, velocity_normed: float):
        """Handle note messages from QuNeo."""

        # change mode
        mode = self.MODE_MAP.get(note)
        if mode is not None and velocity_normed > 0:
            self.set_mode(mode)
            return
        
        if note < 16:
            if self.mode == QuNeoModes.SET_PAD_MODES:
                if velocity_normed > 0:
                    self.advance_pad_mode(note)
            else:
                hid_address = f"quneo.chan{channel_id}.pad{note}.note"
                mode = self.pad_modes[note]
                velocity_boolean = 1.0 if velocity_normed > 0 else 0.0
                if mode == QuNeoPadModes.NOT_USED:
                    return
                elif mode == QuNeoPadModes.ON_OFF:
                    self._send_to_hid_manager(
                        hid_address,
                        QuNeoDataTypes.NOTE,
                        velocity_boolean
                    )
                elif mode == QuNeoPadModes.OFF_ON:
                    self._send_to_hid_manager(
                        hid_address,
                        QuNeoDataTypes.NOTE,
                        1.0 - velocity_boolean
                    )
                elif mode == QuNeoPadModes.ON and velocity_normed > 0:
                    self._send_to_hid_manager(
                        hid_address,
                        QuNeoDataTypes.NOTE,
                        1.0
                    )
                else:
                    print(f"QuNeoManager.note: Unhandled pad mode {mode} for pad {note} with velocity {velocity_normed}")
    
    def cc(self, channel_id: int, control: int, value: int):
        """
        Handle CC messages from QuNeo.
        
        CCs 0-47 are mapped to pads 0-15 with pressure, X, Y.
        CC 0-2: Pad 0 (pressure, x, y)
        CC 3-5: Pad 1 (pressure, x, y)
        etc.
        """
        if control < 48:
            pad = control // 3
            if self.pad_modes[pad] != QuNeoPadModes.NOT_USED:
                param_index = control % 3
                datatype = self.PAD_CC_PARAMS[param_index]
                hid_address = f"quneo.chan{channel_id}.pad{pad}.{datatype.name}"
                self._send_to_hid_manager(
                    hid_address,
                    datatype,
                    value / 127.0
                )
    
    def supriya_midiin(self, message, timestamp, data=None):
        
        msg_dataclass = MidiMessage.parse(message)
        t = type(msg_dataclass)
        channel_id = msg_dataclass.channel_id # type: ignore

        if t == supriya_midi.messages.NoteOnMessage:
            self.note(channel_id, msg_dataclass.note_number, msg_dataclass.velocity / 127.0) # type: ignore
        elif t == supriya_midi.messages.NoteOffMessage:
            self.note(channel_id, msg_dataclass.note_number, 0.0) # type: ignore
        elif t == supriya_midi.messages.ControllerChangeMessage:
            self.cc(channel_id, msg_dataclass.controller_number, msg_dataclass.controller_value) # type: ignore
        else:
            print(f"QUNEO::supriya_midiin: Unhandled MIDI message type: {t} with data: {msg_dataclass}")
    
    # ==================== Mode Management ====================
    
    def set_mode(self, mode: QuNeoModes):
        self.mode = mode
        print(f"Setting QuNeo mode to {self.mode.name}")

    def advance_pad_mode(self, pad: int):
        """Advance the mode of a specific pad."""
        if 0 <= pad < 16:
            current_mode = self.pad_modes[pad]
            new_mode = QuNeoPadModes((current_mode.value + 1) % len(QuNeoPadModes))
            self.pad_modes[pad] = new_mode
            self._update_pad_colors()
        else:
            print(f"Invalid pad number: {pad}. Must be between 0 and 15.")
    # ==================== Data Routing ====================
    
    def _send_to_hid_manager(
        self,
        hid_address: str,
        data_type: QuNeoDataTypes,
        value: float
    ):
        # Check if the mode allows this data type through
        if self.mode == QuNeoModes.PLAY or self.mode.value == data_type.value:
            self.hid_manager.hidin(HIDMsg(hid_address, value))
    
    # ==================== LED Feedback ====================
    
    def _send_note_on(self, note: int, velocity: int, channel: int = 0):
        """Send a note on message to the QuNeo for LED control."""
        if self.midi_out:
            msg = supriya_midi.messages.NoteOnMessage(note_number=note, velocity=velocity, channel_id=channel)
            self.midi_out.send_message(msg.serialize())
        # else:
        #     print(f"QuNeo MIDI output not initialized. Cannot send note_on for LED feedback. Note: {note}, Velocity: {velocity}, Channel: {channel}")
    
    def _send_note_off(self, note: int, velocity: int = 0, channel: int = 0):
        """Send a note off message to the QuNeo for LED control."""
        if self.midi_out:
            msg = supriya_midi.messages.NoteOffMessage(note_number=note, velocity=velocity, channel_id=channel)
            self.midi_out.send_message(msg.serialize())
        # else:
            # print(f"QuNeo MIDI output not initialized. Cannot send note_off for LED feedback. Note: {note}, Velocity: {velocity}, Channel: {channel}")
    
    def _set_pad_green(self, pad: int):
        """Set pad LED to green."""
        self._send_note_on(pad * 2, 127, 0)
        self._send_note_on(pad * 2 + 1, 0, 0)
    
    def _set_pad_red(self, pad: int):
        """Set pad LED to red."""
        self._send_note_on(pad * 2, 0, 0)
        self._send_note_on(pad * 2 + 1, 127, 0)
    
    def _set_pad_yellow(self, pad: int):
        """Set pad LED to yellow (green + some red)."""
        self._send_note_on(pad * 2, 127, 0)
        self._send_note_on(pad * 2 + 1, 24, 0)
    
    def _set_pad_white(self, pad: int):
        """Set pad LED to white (off/default)."""
        self._send_note_off(pad * 2, 0, 0)
        self._send_note_off(pad * 2 + 1, 0, 0)
    
    def _update_pad_colors(self):
        for pad in range(len(self.pad_modes)):
            mode = self.pad_modes[pad]
            if mode == QuNeoPadModes.NOT_USED:
                self._set_pad_white(pad)
            elif mode == QuNeoPadModes.ON_OFF:
                self._set_pad_green(pad)
            elif mode == QuNeoPadModes.OFF_ON:
                self._set_pad_yellow(pad)
            elif mode == QuNeoPadModes.ON:
                self._set_pad_red(pad)
    
    def hide_pad_modes(self):
        """Turn off all pad LEDs."""
        for i in range(16):
            self._set_pad_white(i)
    
    # ==================== Pad Mode Accessors ====================
    
    def close(self):
        if self.midi_out:
            self.midi_out.close_port()

class GlobalKeyFilter(QObject):
    def __init__(self, on_press=None, on_release=None):
        super().__init__()
        self.on_press = on_press
        self.on_release = on_release

    def eventFilter(self, obj, event):
        if obj is not QApplication.instance().focusWidget():
            return False
        if event.type() == QEvent.KeyPress and not event.isAutoRepeat() and self.on_press:
            self.on_press(event)
        elif event.type() == QEvent.KeyRelease and not event.isAutoRepeat() and self.on_release:
            self.on_release(event)
        return False

class HIDMsg:
    """A simple class to represent a HID message."""
    def __init__(self, hidaddr: str, value: float):
        self.hidaddr = hidaddr
        self.value = value

class HIDBridge(QObject):
    hid_signal = Signal(HIDMsg)

class ToggleMode(Enum):
    ADVANCE = "advance"            # flip on 1, ignore 0
    MOMENTARY = "momentary"        # 1 when pressed (value>0.5), 0 when released
    INVERTED = "inverted"          # 0 when pressed (value>0.5), 1 when released

class LFOType(Enum):
    SINE = 0
    TRIANGLE = 1
    SAW = 2
    SQUARE = 3

    @classmethod
    def options(cls) -> list[tuple[str, int]]:
        return [
            ("Sine", cls.SINE.value),
            ("Triangle", cls.TRIANGLE.value),
            ("Saw", cls.SAW.value),
            ("Square", cls.SQUARE.value),
        ]

TOGGLE_MODE_COLORS = {
    ToggleMode.ADVANCE:   None,                      # use default/mapped color
    ToggleMode.MOMENTARY: "#2a9d8f",                 # teal
    ToggleMode.INVERTED:  "#e76f51",                 # orange
}

class HIDManager(StateSaver,Saveable):
    """A simple class to manage HID devices and their controls."""

    def __init__(self, n_states: int):
        super().__init__()
        self.learning = False
        self.learning_gui_id: Optional[str] = None
        self.gui_id_to_assign_buttons = {}  # gui_id -> AssignmentButton
        self.gui_id_to_gui = {}  # gui_id -> GUI control (SliderA, NumberBoxA, ToggleA, etc.)
        self.hid_to_gui_id: list[dict] = [{} for _ in range(n_states)]  # hidaddr -> gui_id
        self.add_save_attr('hid_to_gui_id')
        self.hid_to_gui_id_states = {}
        self.add_save_attr('hid_to_gui_id_states')
        self.midi_ports = []
        self.current_state = 0

        self.supriya2hidmsg = {
            supriya_midi.messages.ControllerChangeMessage: lambda msg_dc, prefix: HIDMsg(f"{prefix}.chan{msg_dc.channel_id}.cc.{msg_dc.controller_number}", msg_dc.controller_value / 127.0),
            supriya_midi.messages.NoteOnMessage: lambda msg_dc, prefix: HIDMsg(f"{prefix}.chan{msg_dc.channel_id}.note.{msg_dc.note_number}", msg_dc.velocity / 127.0),
            supriya_midi.messages.NoteOffMessage: lambda msg_dc, prefix: HIDMsg(f"{prefix}.chan{msg_dc.channel_id}.note.{msg_dc.note_number}", 0.0),
            supriya_midi.messages.PitchWheelMessage: lambda msg_dc, prefix: HIDMsg(f"{prefix}.chan{msg_dc.channel_id}.pitchwheel", msg_dc.transposition / 8192.0)
        }

        self.bridge = HIDBridge()
        self.bridge.hid_signal.connect(self._process_hid_main_thread)
        self.connect_midi()
        
    def switch_to_state(self,current_state: int):
        self.current_state = current_state
        
        # unsticky all handles
        for gui in self.gui_id_to_gui.values():
            if hasattr(gui, 'is_sticked'):
                gui.is_sticked = False
        
        self.update_assign_buttons()

    def connect_midi(self):
        midi_out_tmp = MidiOut()
        midi_out_devices = {name: i for i, name in enumerate(midi_out_tmp.get_ports())}
        self.quneo = QuNeoManager(
            midi_output_names=list(midi_out_devices.keys()),
            hid_manager=self
            )
        self.add_saveable_item('quneo', self.quneo)
        del midi_out_tmp
        print("MIDI output devices (Supriya):", list(midi_out_devices.keys()))

        midi_in_tmp = MidiIn()
        midi_in_devices = {name: i for i, name in enumerate(midi_in_tmp.get_ports())}
        del midi_in_tmp
        print("MIDI input devices (Supriya):", list(midi_in_devices.keys()))

        if 'nanoKONTROL2 SLIDER/KNOB' in midi_in_devices.keys():
            port_index = midi_in_devices['nanoKONTROL2 SLIDER/KNOB']
            port = MidiIn().open_port(port_index)
            port.set_callback(lambda message, timestamp, data=None: self.supriya_midiin(message, timestamp, data='nk'))
            self.midi_ports.append(port)
            print(f"Opened MIDI input port: 'nanoKONTROL2 SLIDER/KNOB'")
        else:
            print(f"\033[1;33mWarning: 'nanoKONTROL2 SLIDER/KNOB' MIDI device not found.\033[0m")

        if 'Oxygen 25' in midi_in_devices.keys():
            port_index = midi_in_devices['Oxygen 25']
            port = MidiIn().open_port(port_index)
            port.set_callback(lambda message, timestamp, data=None: self.supriya_midiin(message, timestamp, data='oxygen25'))
            self.midi_ports.append(port)
            print(f"Opened MIDI input port: 'Oxygen 25'")
        else:
            print(f"\033[1;33mWarning: 'Oxygen 25' MIDI device not found.\033[0m")

        if 'TouchOSC Bridge' in midi_in_devices.keys():
            port_index = midi_in_devices['TouchOSC Bridge']
            port = MidiIn().open_port(port_index)
            port.set_callback(lambda message, timestamp, data=None: self.supriya_midiin(message, timestamp, data='tosc'))
            self.midi_ports.append(port)
            print(f"Opened MIDI input port: 'TouchOSC Bridge'")
        else:
            print(f"\033[1;33mWarning: 'TouchOSC Bridge' MIDI device not found.\033[0m")

        if 'QUNEO' in midi_in_devices.keys():
            port_index = midi_in_devices['QUNEO']
            port = MidiIn().open_port(port_index)
            port.set_callback(lambda message, timestamp, data=None: self.quneo.supriya_midiin(message, timestamp, data))
            self.midi_ports.append(port)
            print(f"Opened MIDI input port: 'QUNEO'")
        else:
            print(f"\033[1;33mWarning: 'QUNEO' MIDI device not found.\033[0m")

    def load(self, d, is_software_boot = False):
        super().load(d)
        self.update_assign_buttons()

    def supriya_midiin(self, message, timestamp, data=None):
        msg_dataclass = MidiMessage.parse(message)
        t = type(msg_dataclass)

        if t in self.supriya2hidmsg:
            hidmsg = self.supriya2hidmsg[t](msg_dataclass, data)
            self.hidin(hidmsg)

    def _process_hid_main_thread(self, hidmsg: HIDMsg):

        if self.learning:
            if self.gui_id_to_assign_buttons[self.learning_gui_id].is_state_related:
                self.hid_to_gui_id_states[hidmsg.hidaddr] = self.learning_gui_id
            else:
                self.hid_to_gui_id[self.current_state][hidmsg.hidaddr] = self.learning_gui_id

            self.learning = False
            self.learning_gui_id = None
            self.update_assign_buttons()
        else:
            # not learning

            if hidmsg.hidaddr in self.hid_to_gui_id[self.current_state]:
                # see if this hidaddr is mapped to a gui_id, and if so, update the corresponding GUI control
                gui_id = self.hid_to_gui_id[self.current_state][hidmsg.hidaddr]
                if gui_id in self.gui_id_to_gui:
                    self.gui_id_to_gui[gui_id].set_from_hid(hidmsg.value)
            else:
                if hidmsg.hidaddr in self.hid_to_gui_id_states:
                    # see if this hidaddr is mapped to a gui_id, and if so, update the corresponding GUI control
                    gui_id = self.hid_to_gui_id_states[hidmsg.hidaddr]
                    if gui_id in self.gui_id_to_gui:
                        self.gui_id_to_gui[gui_id].set_from_hid(hidmsg.value)

    def keyin(self, key: str, value: float):
        self.hidin(HIDMsg(f"qwerty.{key}", value))
    
    def hidin(self, hidmsg: HIDMsg):
        self.bridge.hid_signal.emit(hidmsg) # type: ignore

    def register_gui(self, gui_id: str, gui):
            self.gui_id_to_gui[gui_id] = gui

    def unregister_mapping(self, gui_id: str):
        hidaddrs_to_remove = [hid for hid, gid in self.hid_to_gui_id[self.current_state].items() if gid == gui_id]
        
        for hid in hidaddrs_to_remove:
            self.hid_to_gui_id[self.current_state].pop(hid, None)
        for hid in hidaddrs_to_remove:
            self.hid_to_gui_id_states.pop(hid, None)

        self.update_assign_buttons()

    def register_assign_button(self, gui_id: str, button):
        self.gui_id_to_assign_buttons[gui_id] = button

    def update_assign_buttons(self):
        # figure out what gui_ids are currently mapped to a HID
        mapped_gui_ids = set(self.hid_to_gui_id[self.current_state].values()) | set(self.hid_to_gui_id_states.values())
        # iterate over all the assign buttons
        for gui_id, btn in self.gui_id_to_assign_buttons.items():
            is_mapped = gui_id in mapped_gui_ids
            btn.apply_style(is_mapped)

    def start_learning(self, gui_id: str):
        self.learning = True
        self.learning_gui_id = gui_id

    def close(self):
        self.quneo.close()
        for port in self.midi_ports:
            port.close_port()

class AssignmentButton(QPushButton):
    """A button that, when pressed, starts the learning process for a given GUI address."""
    def __init__(self, gui_id: str,  hid_manager: HIDManager, dtype: Optional[type] = None, cmd_callback=None, is_state_related: bool = False):
        super().__init__("A")
        self.gui_id = gui_id
        # self.mmm_audio = mmm_audio
        self.cmd_callback = cmd_callback
        self.mode_color = None
        self.lfo_color = None
        self.dtype = dtype # optional for assignment button because for toggles and buttons it isn't used
        self.clicked.connect(self.on_click)
        self.hid_manager = hid_manager
        self.is_state_related = is_state_related
        
        self.hid_manager.register_assign_button(gui_id, self)

    def set_lfo_color(self, color: Optional[str]):
        self.lfo_color = color

    def apply_style(self, is_mapped: bool):
        if self.lfo_color is not None:
            border_color = "#00a0d0" if is_mapped else "#4a4a4a"
            text_color = contrast_text_color(self.lfo_color)
            self.setStyleSheet(
                f"background-color: {self.lfo_color}; color: {text_color}; border: 2px solid {border_color};"
            )
        elif self.mode_color and is_mapped:
            self.setStyleSheet(f"background-color: {self.mode_color}; color: white;")
        elif is_mapped:
            self.setStyleSheet("background-color: #00a0d0; color: white;")
        else:
            self.setStyleSheet("")

    def on_click(self):
        mods = QApplication.keyboardModifiers()
        # print what modifiers are being held when the button is clicked
        # if mods & Qt.ShiftModifier:
        #     print("Shift modifier held")
        # if mods & Qt.ControlModifier:
        #     print("Control modifier held")
        # if mods & Qt.AltModifier:
        #     print("Alt modifier held")
        # if mods & Qt.MetaModifier:
        #     print("Meta modifier held")
        # if mods == Qt.NoModifier:
        #     print("No modifier held")

        if mods & Qt.AltModifier and mods & Qt.ShiftModifier: # it's not "meta" on macOS, it's command
            if self.dtype == float and LFOManager.instance is not None:
                LFOManager.instance.deactivate_control(self.gui_id)
        elif mods & Qt.ShiftModifier:
            self.hid_manager.unregister_mapping(self.gui_id)
        elif mods & Qt.ControlModifier: # it's not "control" on macOS, it's command
            if self.cmd_callback:
                self.cmd_callback()
        elif mods & Qt.AltModifier:
            if self.dtype == float and LFOManager.instance is not None and self.gui_id in self.hid_manager.gui_id_to_gui:
                gui = self.hid_manager.gui_id_to_gui[self.gui_id]
                LFOManager.instance.assign_control(self.gui_id, gui.spec)
        else:
            self.hid_manager.start_learning(self.gui_id)

class HandleA(QWidget):
    """Base class for labeled, spec-mapped, HID-assignable controls."""
    def __init__(self,
                 label: str,
                 dtype: type,
                 mmm_audio: MMMAudio,
                 hid_manager: HIDManager,
                 spec: ControlSpec = ControlSpec(),
                 default: float = 0.0,
                 callback=None,
                 orientation=Qt.Horizontal,
                 run_callback_on_init: bool = True,
                 assign_button: bool = True,
                 gui_id: Optional[str] = None,
                 software_boot_override: Optional[float] = None,
                 is_state_settable: bool = True,
                 requires_stickiness: bool = False
            ):
        super().__init__()
        self.label_text = label
        self.spec = spec
        self.callback = callback
        self.mmm_audio = mmm_audio
        self.display = QLabel(f"{default:.4f}")
        self.label = QLabel(self.label_text)
        self.dtype = dtype
        self.is_state_settable = is_state_settable
        self.software_boot_override = software_boot_override
        self.is_sticked = False
        self.requires_stickiness = requires_stickiness

        self.handle = self._create_handle(orientation, default)

        if orientation == Qt.Vertical:
            self.display.setAlignment(Qt.AlignHCenter)
            self.label.setAlignment(Qt.AlignHCenter)
            self.layout = QVBoxLayout()
        elif orientation == Qt.Horizontal:
            self.display.setFixedWidth(60)
            self.label.setFixedWidth(100)
            self.layout = QHBoxLayout()
        else:
            raise ValueError("Invalid orientation")

        self.layout.setContentsMargins(0, 0, 0, 0)
        self.layout.addWidget(self.label)
        self.layout.addWidget(self.handle, alignment=Qt.AlignHCenter if orientation == Qt.Vertical else Qt.Alignment(0))
        self.layout.addWidget(self.display)

        if assign_button:
            self.assign_button = AssignmentButton(gui_id if gui_id else self.label_text, dtype=self.dtype, hid_manager=hid_manager)
            if orientation == Qt.Horizontal:
                self.assign_button.setFixedWidth(30)
            self.layout.addWidget(self.assign_button)

        self.setLayout(self.layout)
        self._set_norm(spec.normalize(clip(default, spec.min, spec.max)))
        self._connect_handle()

        if gui_id:
            hid_manager.register_gui(gui_id, self)

        if run_callback_on_init:
            self._update_text_display()
            self._action()

    # this method is needed so that if the GUI is controlled by a mouse it will work
    def update(self):
        self._update_text_display()
        self._action()

    def _update_text_display(self):
        v = self.get_value()
        self.display.setText(f"{v:.2f}")

    def _action(self):
        if self.callback:
            self.callback(self.get_value())

    def value_action(self, value: float):
        self.value(value)
        self._action()
        

    def value(self, val: float):
        norm_val = self.spec.normalize(clip(val, self.spec.min, self.spec.max))
        
        # Block signals so the UI update doesn't trigger a recursive _action()
        if hasattr(self, 'handle'):
            was_blocked = self.handle.blockSignals(True)
            self._set_norm(norm_val)
            self.handle.blockSignals(was_blocked)
        else:
            self._set_norm(norm_val)
            
        self._update_text_display()

    # ============================================================================================================================
    def get_value(self):
        return self.spec.unnormalize(self._get_norm())

    # redundantly calls .get_value(), but is clearer when saving/loading state
    # it allows for "polymorphic" saving (the saver can just call .save() on any control and get the correct value)
    def save(self):
        return self.get_value()

    # ============================================================================================================================
    def value_action_from_norm(self, value: float):
        self.value_action(self.spec.unnormalize(value))

    # redundantly calls .value_action_from_norm(), but is clearer when updating from HID input
    # it allows for "polymorphic" updating (the updater can just call .set_from_hid() on any control and get the correct behavior)
    def set_from_hid(self, value: float):
        if not self.requires_stickiness or self.is_sticked:
            self.value_action_from_norm(value)
        else:
            self.check_if_sticked(value)
    # ============================================================================================================================
    
    def check_if_sticked(self, value: float):
        if abs(self._get_norm() - value) < 0.03:  # 3% threshold for "stickiness"
            self.is_sticked = True
            self.value_action_from_norm(value)

    # Currently (I think) the only way this method is called is
    # 1. when the software boots, or, 
    # 2. when a state is loaded from a state button
    # so therefore I think this logic works 
    def load(self, v: float, is_software_boot: bool = False):
        if is_software_boot and self.software_boot_override is not None:
            self.value_action(self.software_boot_override)
            self.is_sticked = False
        elif self.is_state_settable:
            self.value_action(v)
            self.is_sticked = False

    def _create_handle(self, orientation, default) -> QWidget:
        raise NotImplementedError

    def _get_norm(self) -> float:
        raise NotImplementedError

    def _set_norm(self, value: float):
        raise NotImplementedError

    def _connect_handle(self):
        raise NotImplementedError


class SliderA(HandleA):
    """A labeled slider with spec mapping and HID assignment."""
    def __init__(self, *args, resolution: int = 1000, dtype: type, mmm_audio: MMMAudio, **kwargs):
        self.resolution = resolution
        super().__init__(*args, dtype=dtype, mmm_audio=mmm_audio, **kwargs)

    def _create_handle(self, orientation, default):
        handle = QSlider(orientation)
        handle.setMinimum(0)
        handle.setMaximum(self.resolution)
        return handle

    def _get_norm(self) -> float:
        return self.handle.value() / self.resolution

    def _set_norm(self, value: float):
        self.handle.setValue(int(value * self.resolution))

    def _connect_handle(self):
        self.handle.valueChanged.connect(self.update)


class NumberBoxA(HandleA):
    """A labeled number box with spec mapping and HID assignment."""
    def __init__(self, *args, decimals: int = 4, color_by_value: bool = False, dtype: type, mmm_audio: MMMAudio, **kwargs):
        self._decimals = decimals
        self._color_by_value = color_by_value
        super().__init__(*args, dtype=dtype, mmm_audio=mmm_audio, **kwargs)

    def _create_handle(self, orientation, default):
        handle = QDoubleSpinBox()
        handle.setDecimals(self._decimals)
        handle.setRange(self.spec.min, self.spec.max)
        handle.setValue(default)
        return handle

    def _get_norm(self) -> float:
        return self.spec.normalize(self.handle.value())

    def _set_norm(self, value: float):
        self.handle.setValue(self.spec.unnormalize(value))

    def _connect_handle(self):
        self.handle.valueChanged.connect(self.update)

    def _update_text_display(self):
        v = self.get_value()
        self.display.setText(f"{v:.{self._decimals}f}")
        if self._color_by_value:
            t = max(0.0, min(1.0, (v - self.spec.min) / (self.spec.max - self.spec.min)))
            r = int(158 + t * (76 - 158))
            g = int(158 + t * (175 - 158))
            b = int(158 + t * (80 - 158))
            
            self.handle.setStyleSheet(
                f"QDoubleSpinBox {{ background-color: rgb({r}, {g}, {b}); color: black; }}"
            )

class RotatedLabel(QLabel):
    def __init__(self, text, parent=None):
        super().__init__(text, parent)

    def paintEvent(self, event):
            painter = QPainter(self)
            
            painter.translate(self.width() / 2, self.height() / 2)
            painter.rotate(-90) 
            
            # Draw the text using the widget's actual alignment!
            painter.drawText(
                int(-self.height() / 2), 
                int(-self.width() / 2), 
                self.height(), 
                self.width(), 
                self.alignment(), # <--- Changed this line
                self.text()
            )
            painter.end()

    # Swap width and height so layout managers allocate space correctly
    def sizeHint(self):
        size = super().sizeHint()
        return QSize(size.height(), size.width())

    def minimumSizeHint(self):
        size = super().minimumSizeHint()
        return QSize(size.height(), size.width())

class ToggleA(QWidget):
    """A convenience widget that combines a label, a checkbox, and an assign button."""
    _MODE_CYCLE = [ToggleMode.ADVANCE, ToggleMode.MOMENTARY, ToggleMode.INVERTED]

    def __init__(self,
                label: str,
                # mmm_audio,
                hid_manager: HIDManager,
                default: bool = False,
                callback=None,
                assign_button: bool = True,
                run_callback_on_init: bool = True,
                gui_id: Optional[str] = None,
                software_boot_override: Optional[bool] = None
            ):
        super().__init__()
        self.label_text = label
        # self.mmm_audio = mmm_audio
        self.layout = QHBoxLayout()
        self.layout.setContentsMargins(0, 0, 0, 0)
        self.layout.setSpacing(8)
        self.mode = ToggleMode.ADVANCE
        self.software_boot_override = software_boot_override

        self.label = QLabel(self.label_text)
        self.label.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.layout.addWidget(self.label)

        self.toggle = QCheckBox()
        self.toggle.setChecked(default)
        self.toggle.setFixedWidth(14)
        self.layout.addWidget(self.toggle)
        self.hid_manager = hid_manager

        if assign_button:
            self.assign_button = AssignmentButton(
                gui_id if gui_id else self.label_text,
                cmd_callback=self._cycle_mode,
                hid_manager=hid_manager
                # mmm_audio=self.mmm_audio, # not used for toggles, only for sliders with alt-click lfo assignment
            )
            self.assign_button.setFixedWidth(30)
            self.layout.addWidget(self.assign_button)
        else:
            self.assign_button = None

        self.setLayout(self.layout)
        self.callback = callback
        self.toggle.toggled.connect(self.update)

        if gui_id:
            self.hid_manager.register_gui(gui_id, self)

        if run_callback_on_init:
            self.update()

    def _cycle_mode(self):
        idx = self._MODE_CYCLE.index(self.mode)
        self.mode = self._MODE_CYCLE[(idx + 1) % len(self._MODE_CYCLE)]
        self._update_mode_style()

    def _update_mode_style(self):
        if self.assign_button is None:
            return
        self.assign_button.mode_color = TOGGLE_MODE_COLORS[self.mode]
        self.hid_manager.update_assign_buttons()

    def update(self):
        v = self.toggle.isChecked()
        if self.callback:
            self.callback(v)

    def value_action(self, value: float):
        self.toggle.setChecked(value > 0.5)
        self.update()
    
    def value(self, val: bool):
        self.toggle.blockSignals(True)
        self.toggle.setChecked(val)
        self.toggle.blockSignals(False)

    def set_from_hid(self, value: float):
        if self.mode == ToggleMode.ADVANCE:
            if value > 0.5:
                self.toggle.setChecked(not self.toggle.isChecked())
                self.update()
        elif self.mode == ToggleMode.MOMENTARY:
            self.toggle.setChecked(value > 0.5)
            self.update()
        else:  # INVERTED
            self.toggle.setChecked(value <= 0.5)
            self.update()
            
    def get_value(self) -> bool:
        return self.toggle.isChecked()

    def save(self):
        return {"checked": self.toggle.isChecked(), "mode": self.mode.value}

    def load(self, d, is_software_boot: bool = False):
        if is_software_boot and self.software_boot_override is not None:
            self.value_action(self.software_boot_override)
        else:
            self.toggle.setChecked(d.get("checked", False))
            self.mode = ToggleMode(d.get("mode", ToggleMode.ADVANCE.value))
            self._update_mode_style()
            self.update()

class ButtonA(QWidget):
    
    def __init__(self,
                 text: str,
                #  mmm_audio: Optional[MMMAudio] = None,
                hid_manager: HIDManager,
                 callback=None,
                 assign_button: bool = True,
                 gui_id: Optional[str] = None,
                 is_state_store_or_recall: bool = False,
            ):
        super().__init__()
        self.layout = QHBoxLayout()
        self.layout.setContentsMargins(0, 0, 0, 0)
        self.layout.setSpacing(8)

        self.button = QPushButton(text)
        self.layout.addWidget(self.button)

        if assign_button:
            self.assign_button = AssignmentButton(
                gui_id if gui_id else text,
                hid_manager=hid_manager,
                is_state_related=is_state_store_or_recall
                # mmm_audio=mmm_audio
            )
            self.assign_button.setFixedWidth(30)
            self.layout.addWidget(self.assign_button)
        else:
            self.assign_button = None

        self.setLayout(self.layout)
        self.callback = callback
        self.button.pressed.connect(self.update)

        if gui_id:
            hid_manager.register_gui(gui_id, self)

    def update(self):
        if self.callback:
            self.callback()

    def value_action(self, value: float):
        if value > 0.5:
            self.button.click()
        # self.update()

    def set_from_hid(self, value: float):
        self.value_action(value)

def contrast_text_color(color: str) -> str:
    return "#111111" if QColor(color).lightness() > 140 else "#ffffff"

def panel_fill_color(color: str) -> str:
    qcolor = QColor(color)
    return f"rgba({qcolor.red()}, {qcolor.green()}, {qcolor.blue()}, 48)"

def slot_color(idx: int) -> str:
    return QColor.fromHsv((idx * 137) % 360, 140, 235).name()

class EnumFieldA(QWidget):
    def __init__(
        self,
        label: str,
        options: list[tuple[str, int]],
        default: int,
        callback=None,
        is_state_settable: bool = True,
        software_boot_override: Optional[str] = None
    ):
        super().__init__()
        self.callback = callback
        self.is_state_settable = is_state_settable
        self.software_boot_override = software_boot_override

        layout = QHBoxLayout()
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)

        self.label = QLabel(label)
        self.label.setFixedWidth(70)
        self.combobox = QComboBox()
        for text, value in options:
            self.combobox.addItem(text, value)
        self.set_value(default, emit=False)

        layout.addWidget(self.label)
        layout.addWidget(self.combobox)
        self.setLayout(layout)

        self.combobox.currentIndexChanged.connect(self.update)

    # this automatically get's called when it changes
    def update(self):
        if self.callback:
            self.callback(self.get_value())

    def get_value(self) -> int:
        return int(self.combobox.currentData())

    def set_value(self, value: int, emit: bool = True):
        idx = self.combobox.findData(value)
        if idx < 0:
            return

        if emit:
            self.combobox.setCurrentIndex(idx)
            return

        was_blocked = self.combobox.blockSignals(True)
        self.combobox.setCurrentIndex(idx)
        self.combobox.blockSignals(was_blocked)

    def save(self) -> str:
        return self.combobox.currentText()

    def load(self, value: str, is_software_boot: bool = False):

        if is_software_boot:
            if self.software_boot_override is None:
                self.set_value(self.combobox.findText(str(value)), emit=True)
            else:
                self.set_value(self.combobox.findText(str(self.software_boot_override)), emit=True)
        else:
            # setting a state
            if self.is_state_settable:

                idx = self.combobox.findText(str(value))
                
                if idx >= 0:
                    # Block signals to prevent emitting during the programmatic update
                    was_blocked = self.combobox.blockSignals(True)
                    self.combobox.setCurrentIndex(idx)
                    self.combobox.blockSignals(was_blocked)
                    self.update()

class LFOPanel(QGroupBox):
    def __init__(self, idx: int, manager: "LFOManager"):
        super().__init__(f"LFO {idx}")
        self.idx = idx
        self.manager = manager
        self.target_gui_id: Optional[str] = None
        self.active = False

        layout = QVBoxLayout()
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(4)

        self.status_label = QLabel()
        self.target_label = QLabel()
        self.target_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.target_label.setWordWrap(True)

        self.min_field = NumberBoxA(
            dtype=float,
            mmm_audio=self.manager.mmm_audio,
            label="Min",
            default=0.0,
            run_callback_on_init=False,
            callback=lambda _value: self.manager.on_slot_shape_changed(self.idx),
        )
        self.max_field = NumberBoxA(
            dtype=float,
            mmm_audio=self.manager.mmm_audio,
            label="Max",
            default=1.0,
            run_callback_on_init=False,
            callback=lambda _value: self.manager.on_slot_shape_changed(self.idx),
        )
        self.exponent_field = NumberBoxA(
            dtype=float,
            mmm_audio=self.manager.mmm_audio,
            label="Exponent",
            default=1.0,
            spec=ControlSpec(0.01, 10.0, 10),
            run_callback_on_init=False,
            callback=lambda _value: self.manager.on_slot_shape_changed(self.idx),
        )
        self.freq_handle = SliderA(
            label="Freq",
            mmm_audio=self.manager.mmm_audio,
            spec=ControlSpec(0.1, 1000.0, 5),
            default=1.0,
            callback=lambda value: self.manager.on_slot_freq_changed(self.idx, value),
            assign_button=True,
            run_callback_on_init=False,
            gui_id=f"lfo.{idx}.freq",
            dtype=float,
        )
        self.type_field = EnumFieldA(
            "Type",
            options=LFOType.options(),
            default=LFOType.SINE.value,
            callback=lambda value: self.manager.on_slot_type_changed(self.idx, value),
        )

        layout.addWidget(self.status_label)
        layout.addWidget(self.target_label)
        layout.addWidget(self.min_field)
        layout.addWidget(self.max_field)
        layout.addWidget(self.exponent_field)
        layout.addWidget(self.freq_handle)
        layout.addWidget(self.type_field)
        self.setLayout(layout)

        self.apply_color(None)
        self._update_labels()

    def has_target(self) -> bool:
        return self.active and self.target_gui_id is not None

    def activate(self, gui_id: str, spec: ControlSpec):
        self.target_gui_id = gui_id
        self.active = True
        self.min_field.set_value(spec.min, emit=False)
        self.max_field.set_value(spec.max, emit=False)
        self.exponent_field.set_value(spec.exp, emit=False)
        self._update_labels()

    def deactivate(self):
        self.target_gui_id = None
        self.active = False
        self._update_labels()

    def assignment_payload(self) -> list[str]:
        if self.target_gui_id is None:
            raise ValueError("Cannot assign an LFO slot without a target gui_id.")

        return [
            str(self.idx),
            self.target_gui_id,
            str(self.min_field.get_value()),
            str(self.max_field.get_value()),
            str(self.exponent_field.get_value()),
        ]

    def save(self) -> dict:
        return {
            "target_gui_id": self.target_gui_id,
            "active": self.active,
            "min": self.min_field.save(),
            "max": self.max_field.save(),
            "exponent": self.exponent_field.save(),
            "freq": self.freq_handle.save(),
            "type": self.type_field.save(),
        }

    def load(self, d: dict, is_software_boot: bool = False):
        self.target_gui_id = d.get("target_gui_id")
        self.active = d.get("active", False)
        self.min_field.value(float(d.get("min", 0.0)))
        self.max_field.value(float(d.get("max", 1.0)))
        self.exponent_field.value(float(d.get("exponent", 1.0)))
        was_blocked = self.freq_handle.handle.blockSignals(True)
        self.freq_handle.value(float(d.get("freq", 1.0)))
        self.freq_handle.handle.blockSignals(was_blocked)
        self.type_field.load(d.get("type", LFOType.SINE.value), is_software_boot=is_software_boot)
        self._update_labels()

    def _update_labels(self):
        if self.has_target():
            self.status_label.setText("Assigned")
            self.target_label.setText(f"Target: {self.target_gui_id}")
        else:
            self.status_label.setText("Available")
            self.target_label.setText("Target: Available")

    def apply_color(self, color: Optional[str]):
        if color is None:
            self.setStyleSheet(
                "QGroupBox { border: 1px solid #555; border-radius: 6px; margin-top: 8px; padding-top: 12px; } "
                "QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 3px 0 3px; }"
            )
            return

        text_color = contrast_text_color(color)
        self.setStyleSheet(
            f"QGroupBox {{ background-color: {panel_fill_color(color)}; border: 2px solid {color}; border-radius: 6px; margin-top: 8px; padding-top: 12px; }} "
            f"QGroupBox::title {{ subcontrol-origin: margin; left: 8px; padding: 0 3px 0 3px; color: {text_color}; }} "
            f"QLabel {{ color: {text_color}; }}"
        )

class LFOManager:
    instance: Optional["LFOManager"] = None
    n_lfos = 16

    def __init__(self, mmm_audio: MMMAudio, hid_manager: HIDManager):
        self.mmm_audio = mmm_audio
        self.hid_manager = hid_manager
        self.tab = QWidget()
        self.panels: list[LFOPanel] = []

        tab_layout = QVBoxLayout()
        tab_layout.setContentsMargins(0, 0, 0, 0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        content = QWidget()
        content_layout = QGridLayout()
        content_layout.setContentsMargins(4, 4, 4, 4)
        content_layout.setSpacing(6)

        for idx in range(self.n_lfos):
            panel = LFOPanel(idx, self)
            self.panels.append(panel)
            content_layout.addWidget(panel, idx // 2, idx % 2)

        content_layout.setColumnStretch(0, 1)
        content_layout.setColumnStretch(1, 1)
        content_layout.setRowStretch((self.n_lfos + 1) // 2, 1)
        content.setLayout(content_layout)
        scroll.setWidget(content)
        tab_layout.addWidget(scroll)
        self.tab.setLayout(tab_layout)

        LFOManager.instance = self
        self.refresh_visuals()

    def assign_control(self, gui_id: str, spec: ControlSpec) -> bool:
        existing_idx = self._find_slot_for_gui_id(gui_id)
        if existing_idx is not None:
            self._send_type(existing_idx)
            self._send_freq(existing_idx)
            self._send_assignment(existing_idx)
            self.refresh_visuals()
            return True

        available_idx = self._find_first_available_slot()
        if available_idx is None:
            self._warn(f"No available LFO slots for {gui_id}.")
            return False

        panel = self.panels[available_idx]
        panel.activate(gui_id, spec)
        self._send_type(available_idx)
        self._send_freq(available_idx)
        self._send_assignment(available_idx)
        self.refresh_visuals()
        return True

    def deactivate_control(self, gui_id: str) -> bool:
        slot_idx = self._find_slot_for_gui_id(gui_id)
        if slot_idx is None:
            self._warn(f"No active LFO is assigned to {gui_id}.")
            return False

        self.panels[slot_idx].deactivate()
        self.mmm_audio.send_int("lfo_manager.deactivate", slot_idx)
        self.refresh_visuals()
        return True

    def on_slot_shape_changed(self, idx: int):
        if self.panels[idx].has_target():
            self._send_assignment(idx)

    def on_slot_type_changed(self, idx: int, value: int):
        self.mmm_audio.send_int(f"lfo_manager.{idx}.type", value)

    def on_slot_freq_changed(self, idx: int, value: float):
        self.mmm_audio.send_float(f"lfo_manager.{idx}.freq", value)

    def save(self) -> dict:
        return {"slots": [panel.save() for panel in self.panels]}

    def load(self, d: SaveValue, is_software_boot: bool = False):
        if not isinstance(d, dict):
            return

        slot_states = d.get("slots", [])
        for idx, panel in enumerate(self.panels):
            if idx < len(slot_states):
                panel.load(slot_states[idx], is_software_boot=is_software_boot)
            else:
                panel.load({}, is_software_boot=is_software_boot)
        self.refresh_visuals()
        self.sync_to_mojo()

    def sync_to_mojo(self):
        for idx, panel in enumerate(self.panels):
            self._send_type(idx)
            self._send_freq(idx)
            if panel.has_target():
                self._send_assignment(idx)
            else:
                self.mmm_audio.send_int("lfo_manager.deactivate", idx)

    def _find_first_available_slot(self) -> Optional[int]:
        for idx, panel in enumerate(self.panels):
            if not panel.has_target():
                return idx
        return None

    def _find_slot_for_gui_id(self, gui_id: str) -> Optional[int]:
        for idx, panel in enumerate(self.panels):
            if panel.has_target() and panel.target_gui_id == gui_id:
                return idx
        return None

    def _send_assignment(self, idx: int):
        self.mmm_audio.send_strings("lfo_manager.assign", self.panels[idx].assignment_payload())

    def _send_type(self, idx: int):
        self.on_slot_type_changed(idx, self.panels[idx].type_field.get_value())

    def _send_freq(self, idx: int):
        self.on_slot_freq_changed(idx, self.panels[idx].freq_handle.get_value())

    def refresh_visuals(self):
        active_colors = {}
        for idx, panel in enumerate(self.panels):
            color = slot_color(idx) if panel.has_target() else None
            panel.apply_color(color)
            if color is not None and panel.target_gui_id is not None:
                active_colors[panel.target_gui_id] = color

        for gui_id, button in self.hid_manager.gui_id_to_assign_buttons.items():
            button.set_lfo_color(active_colors.get(gui_id))

        self.hid_manager.update_assign_buttons()

    def _warn(self, message: str):
        print(f"\033[1;33mWarning: {message}\033[0m")
        QMessageBox.warning(self.tab, "LFO Manager", message)


MODULE_WINDOW_BUILDERS = {}


def register_module_window_builder(module_name: str, builder):
    MODULE_WINDOW_BUILDERS[module_name] = builder

class ModuleWindow(StateSaver, QWidget):
    def __init__(self, name: str, controlparams: dict, mmm_audio: MMMAudio, hid_manager: HIDManager):
        super().__init__()
        self.name = name
        self.controlparams = controlparams
        self.mmm_audio = mmm_audio
        self.hid_manager = hid_manager
        self.namespace: Optional[str] = controlparams["namespace"]
        self.setWindowTitle(name)
        self.resize(600, 100)
        self.window_layout = QVBoxLayout()
        self.window_layout.setSpacing(2)
        self.window_layout.setContentsMargins(4, 4, 4, 4)

        self._build_param_controls()
        self._build_custom_controls()

        self.setLayout(self.window_layout)

    def msgkey(self, name: str) -> str:
        return f"{self.namespace}.{name}" if self.namespace else name

    def add_widget(self, widget: QWidget, save_key: Optional[str] = None, saveable=None):
        self.window_layout.addWidget(widget)
        if save_key is not None:
            self.add_saveable_item(save_key, saveable if saveable is not None else widget)
        return widget

    def add_section(self, title: str) -> QVBoxLayout:
        section = QGroupBox(title)
        section.setStyleSheet("QGroupBox { background-color: #3a3a3a; border: 1px solid #555; border-radius: 4px; margin-top: 6px; padding-top: 14px; } QGroupBox::title { subcontrol-origin: margin; left: 8px; }")
        section_layout = QVBoxLayout()
        section_layout.setSpacing(4)
        section_layout.setContentsMargins(4, 4, 4, 4)
        section.setLayout(section_layout)
        self.window_layout.addWidget(section)
        return section_layout

    def _build_param_controls(self):
        for param in self.controlparams["params"]:
            if param['type'] == 'float':
                msgkey = self.msgkey(param["name"])
                ha = SliderA(
                    label=param["name"],
                    mmm_audio=self.mmm_audio,
                    hid_manager=self.hid_manager,
                    spec=ControlSpec(param["min"], param["max"], param["exponent"]),
                    default=param["default"],
                    callback=lambda v, key=msgkey: self.mmm_audio.send_float(key, v),
                    assign_button=True,
                    gui_id=msgkey,
                    dtype=float
                )
                self.add_widget(ha, save_key=param["name"])
            elif param['type'] == 'int':
                msgkey = self.msgkey(param["name"])
                ha = SliderA(
                    label=param["name"],
                    mmm_audio=self.mmm_audio,
                    hid_manager=self.hid_manager,
                    spec=ControlSpec(param["min"], param["max"]),
                    default=param["default"],
                    callback=lambda v, key=msgkey: self.mmm_audio.send_int(key, v),
                    resolution=param["max"] - param["min"],
                    assign_button=True,
                    gui_id=msgkey,
                    dtype=int
                )
                self.add_widget(ha, save_key=param["name"])
            elif param['type'] == 'bool':
                msgkey = self.msgkey(param["name"])
                ta = ToggleA(
                    label=param["name"],
                    hid_manager=self.hid_manager,
                    default=param["default"],
                    callback=lambda v, key=msgkey: self.mmm_audio.send_bool(key, v),
                    assign_button=True,
                    gui_id=msgkey
                    # mmm_audio=self.mmm_audio
                )
                self.add_widget(ta, save_key=param["name"])
            elif param['type'] == 'trig':
                msgkey = self.msgkey(param["name"])
                ba = ButtonA(
                    text=param["name"],
                    hid_manager=self.hid_manager,
                    callback=lambda key=msgkey: self.mmm_audio.send_trig(key),
                    assign_button=True,
                    gui_id=msgkey
                    # mmm_audio=self.mmm_audio
                )
                self.add_widget(ba)
            else:
                print(f"Unknown control type: {param['type']} for parameter {param['name']}")

    def _build_custom_controls(self):
        builder = MODULE_WINDOW_BUILDERS.get(self.name)
        if builder is not None:
            builder(self)


def build_spectral_smear_module_window(window: ModuleWindow):
    section_layout = window.add_section("Trigger Multiplier")
    button_row = QHBoxLayout()
    button_row.setContentsMargins(0, 0, 0, 0)
    button_row.setSpacing(6)

    for value in (1, 2, 3):
        button = QPushButton(str(value))
        button.clicked.connect(
            lambda checked=False, trig_value=float(value): window.mmm_audio.send_float(
                window.msgkey("trig_freq_mul"), trig_value
            )
        )
        button_row.addWidget(button)

    button_row.addStretch()
    section_layout.addLayout(button_row)

register_module_window_builder("SpectralSmear", build_spectral_smear_module_window)

def build_fin_module_window(window: ModuleWindow):
    print("Building FIN module window...")
    section_layout = window.add_section("Trigger Multiplier")
    onset_thresh_sl = SliderA(
        label="Onset Thresh",
        mmm_audio=window.mmm_audio,
        hid_manager=window.hid_manager,
        spec=ControlSpec(0.0, 100.0),
        default=0.5,
        dtype=float,
        callback=lambda v: window.mmm_audio.send_float(window.msgkey("onset_thresh"), v),
        assign_button=True,
        gui_id=window.msgkey("onset_thresh")
    )
    section_layout.addWidget(onset_thresh_sl)
    
register_module_window_builder("FIN", build_fin_module_window)

class ModulePanel(StateSaver, QGroupBox):
    def __init__(self, name: str, namespace: str, mmm_audio: MMMAudio, open_callback, hid_manager: HIDManager):
        super().__init__(name)
        self.setStyleSheet("QGroupBox { background-color: #3a3a3a; border: 1px solid #555; border-radius: 4px; margin-top: 6px; padding-top: 14px; } QGroupBox::title { subcontrol-origin: margin; left: 8px; }")
        ns = namespace
        self.hid_manager = hid_manager

        panel_layout = QVBoxLayout()
        panel_layout.setSpacing(2)
        panel_layout.setContentsMargins(4, 4, 4, 4)

        self.vol_handle = SliderA(
            label="Vol",
            mmm_audio=mmm_audio,
            hid_manager=hid_manager,
            spec=ControlSpec(-130.0, 12.0, 0.3),
            default=0.0,
            callback=lambda v, key=f"{ns}.mw.vol": mmm_audio.send_float(key, v),
            assign_button=True,
            dtype=float,
            gui_id=f"{ns}.mw.vol",
            requires_stickiness=True
        )
        self.add_saveable_item("vol", self.vol_handle)
        panel_layout.addWidget(self.vol_handle)

        self.mix_handle = SliderA(
            label="Mix",
            mmm_audio=mmm_audio,
            hid_manager=hid_manager,
            spec=ControlSpec(0.0, 1.0),
            default=1.0,
            callback=lambda v, key=f"{ns}.mw.mix": mmm_audio.send_float(key, v),
            assign_button=True,
            dtype=float,
            gui_id=f"{ns}.mw.mix"
        )
        self.add_saveable_item("mix", self.mix_handle)
        panel_layout.addWidget(self.mix_handle)

        toggles_row = QHBoxLayout()
        open_btn = QPushButton("Open")
        open_btn.clicked.connect(open_callback)
        toggles_row.addWidget(open_btn)

        self.bypass_toggle = ToggleA(
            label="Bypass",
            hid_manager=hid_manager,
            default=False,
            callback=lambda v, key=f"{ns}.mw.bypass": mmm_audio.send_bool(key, v),
            assign_button=True,
            gui_id=f"{ns}.mw.bypass",
            # mmm_audio=mmm_audio
        )
        self.add_saveable_item("bypass", self.bypass_toggle)
        toggles_row.addWidget(self.bypass_toggle)

        self.stop_toggle = ToggleA(
            label="Stop",
            default=False,
            hid_manager=hid_manager,
            callback=lambda v, key=f"{ns}.mw.stop": mmm_audio.send_bool(key, v),
            assign_button=True,
            gui_id=f"{ns}.mw.stop",
            # mmm_audio=mmm_audio
        )
        self.add_saveable_item("stop", self.stop_toggle)
        toggles_row.addWidget(self.stop_toggle)

        panel_layout.addLayout(toggles_row)

        self.setLayout(panel_layout)

class Module(StateSaver, Saveable):
    def __init__(self, name: str, controlparams: dict, mmm_audio, hid_manager: HIDManager):
        super().__init__()
        self.name = name
        self.controlparams = controlparams
        self.window = ModuleWindow(
            name=name, 
            controlparams=controlparams, 
            mmm_audio=mmm_audio,
            hid_manager=hid_manager
        )
        self.add_saveable_item("window", self.window)
        self.panel = ModulePanel(name, controlparams["namespace"], mmm_audio, open_callback=self._open_window, hid_manager=hid_manager)
        self.add_saveable_item("panel", self.panel)

    def _open_window(self, checked=False):
        self.window.show()
        self.window.raise_()
        self.window.activateWindow()
        
class MatrixMixerManager(StateSaver, Saveable):
    def __init__(self, mmm_audio: MMMAudio, num_inputs: int, num_outputs: int, n_states: int):
        super().__init__()
        self.mmm_audio = mmm_audio
        self.num_inputs = num_inputs
        self.num_outputs = num_outputs
        self.states: list[MatrixMixerState] = [MatrixMixerState(mmm_audio, num_inputs, num_outputs) for _ in range(n_states)]
        
    def update(self, state_idx: int, source_idx: int, dest_idx: int, value: float):
        if 0 <= state_idx < len(self.states):
            self.states[state_idx].update(source_idx, dest_idx, value)
        else:
            print(f"Invalid state index: {state_idx}")
    
    def switch_to_state(self, state_idx: int):
        if 0 <= state_idx < len(self.states):
            self.states[state_idx].update_mojo()
        else:
            print(f"Invalid state index: {state_idx}")
        
    def save(self) -> dict:
        return {"states": [state.save() for state in self.states]}

    def load(self, d: dict, is_software_boot: bool = False):
        states_data = d.get("states", [])
        for idx, state in enumerate(self.states):
            if idx < len(states_data):
                state.load(states_data[idx], is_software_boot=is_software_boot)
            else:
                state.load({}, is_software_boot=is_software_boot)
                
    def register_widget(self, src_i: int, dest_i: int, widget):
        for state in self.states:
            state.register_widget(src_i, dest_i, widget)

class MatrixMixerState(StateSaver, Saveable):
    def __init__(self, mmm_audio: MMMAudio, num_inputs: int, num_outputs: int):
        super().__init__()
        self.mmm_audio = mmm_audio
        self.num_inputs = num_inputs
        self.num_outputs = num_outputs
        self.coeffs = [False] * (num_inputs * num_outputs)

        # save the coeffs via them just being a property of this class
        self.add_save_attr("coeffs")
        
        self._widgets = {}  # (src_i, dest_i) -> list of HandleA

    def register_widget(self, src_i: int, dest_i: int, widget):
        key = (src_i, dest_i)
        if key not in self._widgets:
            self._widgets[key] = []
        self._widgets[key].append(widget)

    def update(self, source_idx: int, dest_idx: int, value: bool):
        index = (dest_idx * self.num_inputs) + source_idx
        self.coeffs[index] = value
        self.mmm_audio.send_bools("instrument.matrix_mixer_coeffs", self.coeffs)
        self.sync_widgets(source_idx, dest_idx, value)

    def sync_widgets(self, source_idx: int, dest_idx: int, value: bool):
        for widget in self._widgets.get((source_idx, dest_idx), []):
            if widget.get_value() != value:
                widget.toggle.blockSignals(True)
                widget.value(value)
                widget.toggle.blockSignals(False)
    
    def update_mojo(self):
        self.mmm_audio.send_bools("instrument.matrix_mixer_coeffs", self.coeffs)
        for dest_i in range(self.num_outputs):
            for src_i in range(self.num_inputs):
                index = (dest_i * self.num_inputs) + src_i
                if index < len(self.coeffs):
                    self.sync_widgets(src_i, dest_i, self.coeffs[index])
                else:
                    print(f"Warning: coeffs list is shorter than expected. Expected index {index}, but got {len(self.coeffs)}.")
    
    def load(self, d: dict, is_software_boot: bool = False):
        # overwriting this load method to load them from the saved state and then send them to Mojo
        super().load(d, is_software_boot=is_software_boot)
        self.update_mojo()

class TrainingSignals(QObject):
    finished = Signal(str)

class MLPPanel(StateSaver,QGroupBox):
    def __init__(self, mlp_idx: int, mlp_max_inputs: int, modules: dict[str, Module], mmm_audio: MMMAudio, hid_manager: HIDManager):
        super().__init__(f"MLP {mlp_idx}")
        self.mlp_idx = mlp_idx
        self.mlp_max_inputs = mlp_max_inputs
        self.modules = modules
        self.mmm_audio = mmm_audio
        self.hid_manager = hid_manager
        self.output_ids = []
        self.outputs_norm = [0.0] * len(self.output_ids)
        self.traced_model_path = ""

        self.x = []
        self.y = []

        self.special_cases = {
            "FIN": self.create_fin_module_controls,
        }

        layout = QVBoxLayout()
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(4)

        row1 = QHBoxLayout()

        active_toggle = ToggleA(
            label="Active",
            default=False,
            assign_button=True,
            gui_id=f"mlp.{mlp_idx}.active",
            callback=lambda v: self.mmm_audio.send_bool(f"mlp.{mlp_idx}.active", v),
            hid_manager=self.hid_manager
        )
        active_toggle.setFixedWidth(100)

        self.add_saveable_item("active_toggle", active_toggle)

        row1.addWidget(active_toggle)

        # integer number box to select the number of inputs to use:
        self.num_inputs_field = NumberBoxA(
            label="Num Inputs",
            dtype=int,
            mmm_audio=self.mmm_audio,
            hid_manager=self.hid_manager,
            default=mlp_max_inputs,
            decimals=0,
            spec=ControlSpec(1, mlp_max_inputs),
            assign_button=False,
            run_callback_on_init=False,
            callback=lambda v: self.display_n_inputs(int(v)),
            is_state_settable=False
            )
        self.num_inputs_field.setFixedWidth(120)
        self.add_saveable_item("num_inputs_field", self.num_inputs_field)
        row1.addWidget(self.num_inputs_field)

        output_mod_pum = EnumFieldA(
            label="Output Module",
            options=[(name, idx) for idx, name in enumerate(modules.keys())],
            default=0,
            callback=lambda v: self.on_output_module_changed(v),
            is_state_settable=False
        )

        self.update_current_module(output_mod_pum.get_value())

        self.add_saveable_item("output_mod_pum", output_mod_pum)

        row1.addWidget(output_mod_pum)

        randomize_button = ButtonA(
            text="Randomize",
            callback=self.randomize_outputs,
            assign_button=True,
            gui_id=f"mlp.{mlp_idx}.randomize_outputs",
            hid_manager=self.hid_manager
        )
        row1.addWidget(randomize_button)

        add_points_button = ButtonA(
            text="Add Points",
            assign_button=False,
            callback=self.add_points,
            hid_manager=self.hid_manager
        )

        row1.addWidget(add_points_button)

        clear_points_button = ButtonA(
            text="Clear Points",
            assign_button=False,
            callback=self.clear_points,
            hid_manager=self.hid_manager
        )

        row1.addWidget(clear_points_button)

        layers_label = QLabel("Layers:")
        layers_label.setFixedWidth(50)

        row1.addWidget(layers_label)

        self.layers_text_field = QLineEdit(
            text="5,8"
        )

        self.layers_text_field.setFixedWidth(200)

        row1.addWidget(self.layers_text_field)

        train_button = ButtonA(
            text="Train",
            assign_button=False,
            callback=self.start_training,
            hid_manager=self.hid_manager
        )

        row1.addWidget(train_button)

        send_to_mojo_button = ButtonA(
            text="Send to Mojo",
            assign_button=False,
            callback=self.send_model_path_to_mojo,
            hid_manager=self.hid_manager
        )

        row1.addWidget(send_to_mojo_button)

        load_from_disk_button = ButtonA(
            text="Load from Disk",
            assign_button=False,
            callback=self.load_model_from_disk,
            hid_manager=self.hid_manager
        )

        row1.addWidget(load_from_disk_button)

        self.model_file_display = QLabel("no model")
        self.model_file_display.setFixedWidth(260)

        row1.addWidget(self.model_file_display)

        layout.addLayout(row1)

        row2 = QHBoxLayout()
        # based on the number of inputs being used (and updated if changed) create that many float number
        # boxes that range from 0.0 to 1.0 and have an AssignmentButton next to them for HID learnability
        # these number boxes should be piped to the MLP module in Mojo via the mmm_audio.send_float() method with a message key like "mlp.{mlp_idx}.input.{input_idx}" where input_idx is the index of the input (0 to num_inputs-1)
        self.input_fields: list[NumberBoxA] = []
        for input_idx in range(mlp_max_inputs):
            id = f"mlp.{mlp_idx}.input.{input_idx}"
            input_field = NumberBoxA(
                label=f"{input_idx}",
                hid_manager=self.hid_manager,
                dtype=float,
                spec=ControlSpec(0.0, 1.0),
                default=0.0,
                callback=lambda v,input_idx=input_idx: self.on_input_changed(input_idx, v),
                assign_button=True,
                gui_id=id,
                mmm_audio=self.mmm_audio
            )
            self.add_saveable_item(id, input_field)
            input_field.label.setFixedWidth(10)
            input_field.label.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            input_field.handle.setFixedWidth(80)
            self.input_fields.append(input_field)
            row2.addWidget(input_field) 
        
        row2.addStretch()

        layout.addLayout(row2)

        layout.addStretch()

        self.num_inputs_field.value_action(2)

        self.setLayout(layout)

    def save(self) -> dict:
        d = super().save()
        d['traced_model_path'] = self.traced_model_path
        return d

    def load(self, d: dict, is_software_boot: bool = False):
        # overwriting this load method to load the model path from the saved state and then send to Mojo
        super().load(d, is_software_boot=is_software_boot)

        # only load the model path on software boot
        if is_software_boot:
            self.traced_model_path = d.get('traced_model_path', "")
            if self.traced_model_path != "":
                self.send_model_path_to_mojo()

    def load_model_from_disk(self):
        options = QFileDialog.Options()
        options |= QFileDialog.ReadOnly

        rel_path = Path("instrument/mlp_trainings")
        abs_path = rel_path.resolve()        
        abs_path.mkdir(parents=True, exist_ok=True)

        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Load MLP Model from Disk",
            str(abs_path),  # <--- Pass the absolute string here
            "PyTorch Model Files (*.pt);;All Files (*)",
            options=options
        )

        if file_path:
            self.traced_model_path = file_path
            self.send_model_path_to_mojo()
    
    def send_model_path_to_mojo(self):
        self.mmm_audio.send_string(f"mlp.{self.mlp_idx}.load_model", self.traced_model_path)
        self.model_file_display.setText(Path(self.traced_model_path).name)

    def clear_points(self):
        self.x.clear()
        self.y.clear()

    def _training_worker_with_signal(self, training_args, signals: TrainingSignals):
        train_new_mlp(*training_args)
        signals.finished.emit(training_args[-1])

    def start_training(self):

        print(f"Starting training with {len(self.x)} points and {len(self.y)} outputs.")

        layers = []

        for size in self.layers_text_field.text().split(","):
            size = size.strip()
            if size.isdigit():
                layers.append([ int(size), "sigmoid" ])
            else:
                print(f"Invalid layer size: {size}")
                return

        layers.append([ len(self.y[0]), "sigmoid" ])

        print("Layers:")
        for i,l in enumerate(layers):
            print(f"    {i}: {l[0]} neurons, activation: {l[1]}")

        learn_rate = 0.001
        epochs = 5000
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.traced_model_path = f"instrument/mlp_trainings/{timestamp}_idx={self.mlp_idx}_{self.current_module}.pt"
        args = (self.x, self.y, layers, learn_rate, epochs, self.traced_model_path)
        self.training_signals = TrainingSignals()
        self.training_signals.finished.connect(self.on_training_complete)
        training_thread = threading.Thread(
            target=self._training_worker_with_signal, 
            args=(args, self.training_signals)
        )
        training_thread.start()

    def on_training_complete(self, model_path: str):
        self.send_model_path_to_mojo()

    def add_points(self):
        self.y.append(self.outputs_norm.copy())
        xtmp = []
        for i in range(int(self.num_inputs_field.get_value())):
            xtmp.append(self.input_fields[i].get_value())
        self.x.append(xtmp)

    def update_current_module(self, module_idx: int):
        key = list(self.modules.keys())[module_idx]
        self.current_module = key

    def on_output_module_changed(self, module_idx: int):
        self.output_ids.clear()

        self.update_current_module(module_idx)

        if self.current_module in self.special_cases:
            self.special_cases[self.current_module]()
        else:
            namespace = self.modules[self.current_module].controlparams['namespace']

            for v in self.modules[self.current_module].controlparams['params']:
                if v['type'] == 'float':
                    self.output_ids.append(f"{namespace}.{v['name']}")
        
        self.mmm_audio.send_strings(f"mlp.{self.mlp_idx}.output_ids", self.output_ids)

    def randomize_outputs(self):
        if self.output_ids is None or len(self.output_ids) == 0:
            print("No output IDs available to randomize.")
            return
        
        self.outputs_norm = [random.uniform(0.0, 1.0) for _ in range(len(self.output_ids))]
        self.mmm_audio.send_floats(f"mlp.{self.mlp_idx}.outputs_norm", self.outputs_norm)

    def on_input_changed(self, input_idx: int, v: float):
        self.mmm_audio.send_float(f"mlp.{self.mlp_idx}.input.{input_idx}", v)

    def display_n_inputs(self, n: int):
        self.mmm_audio.send_int(f"mlp.{self.mlp_idx}.n_inputs", n)
        for input_idx, input_field in enumerate(self.input_fields):
            input_field.setVisible(input_idx < n)

    def create_fin_module_controls(self):
        # create a set of controls specific to the FIN module
        self.output_ids.clear()
        for i in range(64):
            self.output_ids.append(f"fin.coeff.{i}")
        for i in range(8):
            self.output_ids.append(f"fin.freq.{i}")
            self.output_ids.append(f"fin.q.{i}")
            self.output_ids.append(f"fin.gain.{i}")

class Instrument(StateSaver):

    def __init__(self, load_path=None, input_device: Optional[str] = "default", output_device: Optional[str] = "default", test_input_file: Optional[str] = None):

        super().__init__()

        self.controlparams = ControlsBridge.get_controls()
        
        self.n_states = 10
        self.current_state = 0
        self.add_save_attr('current_state')

        app = QApplication([])

        self.hid_manager = HIDManager(self.n_states)
        self.add_saveable_item("hid_manager", self.hid_manager)
        
        self.mmm_audio = MMMAudio(
            blocksize=128, 
            graph_name="Instrument", 
            package_name="instrument",
            in_device=input_device,
            out_device=output_device,
            num_input_channels=1 if input_device != "none" else 0,
            num_output_channels=2,
            audio_init_timeout=60
            )
                
        if test_input_file and os.path.isfile(test_input_file):
            self.mmm_audio.send_string("instrument.test_input_file", test_input_file)

        key_filter = GlobalKeyFilter(on_press=self.on_key_press, on_release=self.on_key_release)
        app.installEventFilter(key_filter)

        app.setStyle("Fusion")
        palette = QPalette()
        palette.setColor(QPalette.Window, QColor(53, 53, 53))
        palette.setColor(QPalette.WindowText, Qt.white)
        palette.setColor(QPalette.Base, QColor(25, 25, 25))
        palette.setColor(QPalette.Button, QColor(53, 53, 53))
        palette.setColor(QPalette.Highlight, QColor(42, 130, 218))
        app.setPalette(palette)
        with open("instrument/style.qss", "r") as f:
            app.setStyleSheet(f.read())

        # self.lfo_manager = LFOManager(self.mmm_audio)
        # self.add_saveable_item("lfo_manager", self.lfo_manager)

        # ======================================================
        # Create main window with buttons for each instrument
        # ======================================================

        main_window = QWidget()
        main_window.setWindowTitle("Main")
        main_window.resize(600, 600)
        main_window.closeEvent = self.close
        main_layout = QVBoxLayout()
        
        self.main_layout_row_1 = QHBoxLayout()
        self.create_states_buttons()
        main_layout.addLayout(self.main_layout_row_1, stretch=0)
        
        main_layout_row_2 = QHBoxLayout() # tabs, volume slider

        tabs = QTabWidget()

        modules = {}

        for name in self.controlparams["modules"]:
            modules[name] = Module(name, self.controlparams["modules"][name], self.mmm_audio, hid_manager=self.hid_manager)
            self.add_saveable_item(name, modules[name])  # so that the module gets saved/loaded with the instrument

        self.matrix_mixer_manager = MatrixMixerManager(
            mmm_audio=self.mmm_audio, 
            num_inputs=len(modules) + 1, 
            num_outputs=len(modules) + 1, 
            n_states=self.n_states)
        
        self.add_saveable_item('matrix_mixer_manager',self.matrix_mixer_manager)

        tabs.addTab(self.create_modules_tab(modules), "Modules")
        tabs.addTab(self.create_matrix_tab(modules), "Matrix")
        tabs.addTab(self.create_mlps_tab(modules,self.controlparams['num_mlps'],self.controlparams['mlp_max_inputs']), "MLPs")
        # tabs.addTab(self.lfo_manager.tab, "LFOs")

        # Right column: volume slider (narrow)
        right_layout = QVBoxLayout()

        # pull out the "vol" param
        voldata = next(p for p in self.controlparams["Instrument"]["params"] if p["name"] == "vol")
        mainvolsl = SliderA(
            label="Vol",
            mmm_audio=self.mmm_audio,
            hid_manager=self.hid_manager,
            spec=ControlSpec(voldata["min"], voldata["max"], voldata["exponent"]),
            default=voldata["default"],
            callback=lambda v: self.mmm_audio.send_float("instrument.vol", v),
            assign_button=True,
            orientation=Qt.Vertical,
            gui_id="instrument.vol",
            software_boot_override = -130.0,
            is_state_settable=False,
            dtype=float,
            requires_stickiness=True
        )
        self.add_saveable_item("main_vol", mainvolsl)  # so that the main volume slider gets saved/loaded with the instrument
        mainvolsl.setFixedWidth(60)
        right_layout.addWidget(mainvolsl)

        main_layout_row_2.addWidget(tabs, stretch=1)
        main_layout_row_2.addLayout(right_layout, stretch=0)
        main_layout.addLayout(main_layout_row_2, stretch=1)
        
        main_window.setLayout(main_layout)
        main_window.show()

        self.load_path: Optional[str] = None
        if load_path:
            p = Path(load_path)
            if p.parent.exists():
                # 1. Determine the base name and current increment number
                # Added '_?' to optionally catch the underscore so it's removed from the base_name
                match = re.search(r'_?(\d+)$', p.stem)
                if match:
                    base_name = p.stem[:match.start()]
                    target_num = int(match.group(1)) # Use group(1) to grab only the digits
                else:
                    base_name = p.stem
                    target_num = -1  # Represents "older than 000"

                latest_file = p
                max_num = target_num

                # 2. Scan the directory for the latest incremented file
                for sibling in p.parent.glob(f"*{p.suffix}"):
                    if not sibling.is_file():
                        continue

                    sibling_match = re.search(r'_?(\d+)$', sibling.stem)
                    
                    # File has a number suffix and matches the base name
                    if sibling_match and sibling.stem[:sibling_match.start()] == base_name:
                        s_num = int(sibling_match.group(1))
                    # File matches the base name but has no number suffix
                    elif sibling.stem == base_name:
                        s_num = -1
                    else:
                        continue # Unrelated file

                    if s_num > max_num:
                        max_num = s_num
                        latest_file = sibling

                # 3. If a newer file is found, prompt the user
                if max_num > target_num:
                    reply = QMessageBox.question(
                        main_window,
                        "Newest File Available",
                        f"A newer version of this file was found:\n{latest_file.name}\n\nWould you like to load this latest version instead?",
                        QMessageBox.Yes | QMessageBox.No,
                        QMessageBox.Yes
                    )
                    if reply == QMessageBox.Yes:
                        load_path = str(latest_file)

            self.load_path = load_path
            with open(load_path, "r") as f:
                self.load(json.load(f), is_software_boot=True)
        else:
            self.switch_to_state(0)

        self.mmm_audio.start_audio()

        sys.exit(app.exec())
    def create_mlps_tab(self, modules: dict[str, Module], num_mlps: int, mlp_max_inputs: int):
        mlps_tab = QWidget()
        mlps_tab_layout = QVBoxLayout()
        mlps_tab.setLayout(mlps_tab_layout)

        for mlp_idx in range(num_mlps):
            mlp = MLPPanel(mlp_idx, mlp_max_inputs, modules, self.mmm_audio, hid_manager=self.hid_manager)
            self.add_saveable_item(f"mlp_{mlp_idx}", mlp)
            mlps_tab_layout.addWidget(mlp)

        return mlps_tab

    def create_matrix_tab(self,modules: dict[str, Module]):

        matrix_tab = QWidget()
        matrix_tab_layout = QVBoxLayout()
        matrix_tab.setLayout(matrix_tab_layout)
    
        # Build matrix grid
        dest_names = list(modules.keys()) + ["Output 🔈"]
        src_names = ["Input 🎤"] + list(modules.keys())
        grid = QGridLayout()
        grid.setSpacing(2)

        top_left_corner = QLabel("Sources →\nDestinations ↓")
        grid.addWidget(top_left_corner, 0, 0)

        # Source headers across the top (columns)
        for src_i, src_name in enumerate(src_names):
            col_label = RotatedLabel(src_name)
            col_label.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
            grid.addWidget(col_label, 0, src_i + 1)
        
        # Build the matrix cells - rows are destinations, columns are sources
        for dest_i, dest_name in enumerate(dest_names):
            for src_i, src_name in enumerate(src_names):
                nb = ToggleA(
                    label="",
                    hid_manager=self.hid_manager,
                    default=False,
                    callback=lambda v, s=src_i, d=dest_i: self.matrix_mixer_manager.update(self.current_state, s, d, v),
                    assign_button=False,
                    run_callback_on_init=False
                )
                nb.label.hide()

                grid.addWidget(nb, dest_i + 1, src_i + 1)
                self.matrix_mixer_manager.register_widget(src_i, dest_i, nb)

        dest_label_col = len(src_names) + 1
        for dest_i, dest_name in enumerate(dest_names):
            dest_label_L = QLabel(dest_name)
            dest_label_L.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            grid.addWidget(dest_label_L, dest_i + 1, 0)

            dest_label_R = QLabel(dest_name)
            dest_label_R.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
            grid.addWidget(dest_label_R, dest_i + 1, dest_label_col)
        
        # Source headers across the bottom (columns)
        for src_i, src_name in enumerate(src_names):
            col_label = RotatedLabel(src_name)
            col_label.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            grid.addWidget(col_label, len(dest_names) + 1, src_i + 1)
            
        top_right_corner = QLabel("← Sources\nDestinations ↑")
        grid.addWidget(top_right_corner, len(dest_names) + 1, dest_label_col)

        # Create a horizontal wrapper to hold the grid and a stretch space
        h_wrapper = QHBoxLayout()
        h_wrapper.addLayout(grid)
        h_wrapper.addStretch() # Pushes the grid tightly to the left

        # Add the wrapped grid to your main vertical layout
        matrix_tab_layout.addLayout(h_wrapper)
        matrix_tab_layout.addStretch() # Pushes the grid tightly to the top

        return matrix_tab

    def create_states_buttons(self):

        save_btn = QPushButton("Save")
        save_btn.setFixedWidth(120)
        save_btn.clicked.connect(self.open_save_dialog)
        self.main_layout_row_1.addWidget(save_btn)
        
        save_btn = QPushButton("Save++")
        save_btn.setFixedWidth(120)
        save_btn.clicked.connect(self.increment_and_write_to_disk)
        self.main_layout_row_1.addWidget(save_btn)

        self.main_layout_row_1.addWidget(QLabel("State Stores:"))
        
        self.states_buttons = []

        for i in range(self.n_states):

            store_btn = ButtonA(
                text=f"{i}",
                callback=lambda slot=i: self.switch_to_state(slot),
                assign_button=True,
                gui_id=f"state_slot_save_{i}",
                hid_manager=self.hid_manager,
                is_state_store_or_recall=True
            )
            
            self.states_buttons.append(store_btn)

            self.main_layout_row_1.addWidget(store_btn)
            
    def switch_to_state(self, slot: int):
        if 0 <= slot < self.n_states:
            self.current_state = slot
            self.matrix_mixer_manager.switch_to_state(self.current_state)
            self.hid_manager.switch_to_state(self.current_state)
            
            for i, button in enumerate(self.states_buttons):
                if i == slot:
                    button.button.setStyleSheet("background-color: #2bf1fb; color: black")  # Highlight the active state
                else:
                    button.button.setStyleSheet("")  # Reset all other buttons to default style
            
        else:
            print(f"Invalid state slot: {slot}")
    
    def create_modules_tab(self,modules: dict[str, Module]):
        modules_tab = QWidget()
        modules_tab_layout = QGridLayout()
        modules_tab.setLayout(modules_tab_layout)
    
        n_columns = 4
        for i, module in enumerate(modules.values()):
            modules_tab_layout.addWidget(module.panel, i // n_columns, i % n_columns)

        modules_tab_layout.setRowStretch((len(modules) + n_columns - 1) // n_columns, 1)

        return modules_tab


    def close(self, event):
        self.hid_manager.close()
        self.mmm_audio.stop_audio()
        self.mmm_audio.stop_process()
        event.accept()

    def on_key_press(self, event):
        mods = event.modifiers()
        self.hid_manager.keyin(event.text(), 1.0)
        # print(f"Key pressed: {event.text()!r}, key: {event.key()}, shift={bool(mods & Qt.ShiftModifier)}, ctrl={bool(mods & Qt.ControlModifier)}, alt={bool(mods & Qt.AltModifier)}, meta={bool(mods & Qt.MetaModifier)}")

    def on_key_release(self, event):
        self.hid_manager.keyin(event.text(), 0.0)
        # print(f"Key released: {event.text()!r}, key: {event.key()}")
    
    def load(self, d: dict, is_software_boot = False):
        super().load(d, is_software_boot = is_software_boot)
        self.switch_to_state(d.get('current_state',0))

    def open_save_dialog(self):
        path, _ = QFileDialog.getSaveFileName(
            parent=None, 
            caption="Save State", 
            dir="instrument/_state-saves", 
            filter="JSON Files (*.json);;All Files (*)"
        )
        if path:
            if self.write_to_disk(path):
                self.load_path = path
    
    def write_to_disk(self, path: str) -> bool: # return success or failure
        
        try:
            json.dumps(self.save())  # Test if the data can be serialized
        except TypeError as e:
            print(f"Error serializing state: {e}")
            QMessageBox.critical(None, "Error", f"Failed to serialize state: {e}")
            return False
        
        with open(path, "w") as f:
            json.dump(self.save(), f)
            print(f"State saved to {path}")
            return True
    
    def increment_and_write_to_disk(self):
        if not self.load_path:
            self.open_save_dialog()
        else:
            p = Path(self.load_path)
            
            # Search for any digits at the very end of the filename (stem)
            match = re.search(r'(\d+)$', p.stem)
            
            if match:
                # Separate the text before the number and the number itself
                base_name = p.stem[:match.start()]
                current_num = int(match.group())
                
                # Increment and format to guarantee at least 3 digits (e.g., 001, 042)
                new_stem = f"{base_name}{current_num + 1:03d}"
            else:
                # If no digits are found at the end, append "_000"
                new_stem = f"{p.stem}_000"
                
            # Reconstruct the full path with the new stem and original suffix
            new_path = str(p.with_name(new_stem + p.suffix))
            
            print(f"Incrementing save file to: {new_path}")
            
            if self.write_to_disk(new_path):
                self.load_path = new_path


def main():
    parser = argparse.ArgumentParser(description="Run the Benjolin-inspired Synthesizer")
    parser.add_argument("-l","--load", type=str, help="Path to a JSON file to load the instrument state from")
    parser.add_argument("-i","--input-device", type=str, default="default", help="Audio input device name (default: 'default')")
    parser.add_argument("-o","--output-device", type=str, default="default", help="Audio output device name (default: 'default')")
    parser.add_argument("--print-devices", action="store_true", help="Print available audio devices and exit")
    parser.add_argument("--test-input-file","-tif", type=str, help="Path to a test input audio file to use instead of live audio input")
    args = parser.parse_args()

    if args.print_devices:
        MMMAudio.get_audio_devices(print_them=True)
        exit()

    if args.input_device.lower() == "none":
        args.input_device = None

    if args.output_device.lower() == "none":
        args.output_device = None

    Instrument(
        input_device=args.input_device,
        output_device=args.output_device,
        load_path=args.load,
        test_input_file=args.test_input_file
        )

if __name__ == "__main__":
    main()