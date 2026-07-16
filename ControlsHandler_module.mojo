from mmm_audio import *
# from std.reflection import *
# from std.sys.intrinsics import _type_is_eq

struct ControlsHandler(Movable, Copyable):
    var world: World
    var namespace: String
    # var float32_dict: Dict[String, UnsafePointer[mut=True,Float32,MutUntrackedOrigin]]
    var float64_dict: Dict[String, UnsafePointer[mut=True,Float64,MutUntrackedOrigin]]
    var floats64_dict: Dict[String, UnsafePointer[mut=True,List[Float64],MutUntrackedOrigin]]
    var int_dict: Dict[String, UnsafePointer[mut=True,Int,MutUntrackedOrigin]]
    var bool_dict: Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]
    var trig_dict: Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]
    var strings_dict: Dict[String, UnsafePointer[mut=True,List[String],MutUntrackedOrigin]]
    # var fn_dict: Dict[String, fn(values: List[Float64])]
    var initialized: Bool

    def __init__(out self, world: World, namespace: String):
        self.world = world
        self.initialized = False
        self.namespace = namespace
        # self.float32_dict = Dict[String, UnsafePointer[mut=True,Float32,MutUntrackedOrigin]]()
        self.float64_dict = Dict[String, UnsafePointer[mut=True,Float64,MutUntrackedOrigin]]()
        self.floats64_dict = Dict[String, UnsafePointer[mut=True,List[Float64],MutUntrackedOrigin]]()
        self.int_dict = Dict[String, UnsafePointer[mut=True,Int,MutUntrackedOrigin]]()
        self.bool_dict = Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]()
        self.trig_dict = Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]()
        self.strings_dict = Dict[String, UnsafePointer[mut=True,List[String],MutUntrackedOrigin]]()
        # self.fn_dict = Dict[String, fn(values: List[Float64])]()

    def notify_update(self, name: String, mut values: List[Float64]) -> Bool:
        if self.world[].top_of_block():
            try:
                fso = self.world[].messenger_manager().get_floats(name)
                if fso:
                    values = fso.value().copy()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False
    
    # def notify_update(self, name: String, mut value: Float32) -> Bool:
    #     if self.world[].top_of_block():
    #         try:
    #             fo = self.world[].messenger_manager().get_float(name)
    #             if fo:
    #                 value = Float32(fo.value())
    #                 return True
    #         except e:
    #             print("Error in ControlsHandler notify_update: ", e)
    #     return False
    
    def notify_update(self, name: String, mut value: Float64) -> Bool:
        if self.world[].top_of_block():
            try:
                fo = self.world[].messenger_manager().get_float(name)
                if fo:
                    value = fo.value()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False

    def notify_update(self, name: String, mut value: List[String]) -> Bool:
        if self.world[].top_of_block():
            try:
                fo = self.world[].messenger_manager().get_strings(name)
                if fo:
                    value = fo.value().copy()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False
    
    def notify_update(self, name: String, mut value: List[Bool]) -> Bool:
        if self.world[].top_of_block():
            try:
                fo = self.world[].messenger_manager().get_bools(name)
                if fo:
                    value = fo.value().copy()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False

    def notify_update(self, name: String, mut value: String) -> Bool:
        if self.world[].top_of_block():
            try:
                fo = self.world[].messenger_manager().get_string(name)
                if fo:
                    value = fo.value()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False

    def notify_update(self, name: String, mut value: Int) -> Bool:
        if self.world[].top_of_block():
            try:
                io = self.world[].messenger_manager().get_int(name)
                if io:
                    value = io.value()
                    return True
            except e:
                print("Error in ControlsHandler notify_update: ", e)
        return False

    # =======================
    # ADD CONTROLS
    # =======================

    def add_control(mut self, var name: String, control: List[Float64]):
        self.floats64_dict[self.namespace + "." + name] = UnsafePointer[mut=True,List[Float64],MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    def add_control(mut self, var name: String, control: List[String]):
        self.strings_dict[self.namespace + "." + name] = UnsafePointer[mut=True,List[String],MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    def add_control(mut self, var name: String, mut control: Bool):
        self.bool_dict[self.namespace + "." + name] = UnsafePointer[mut=True,Bool,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    def add_control(mut self, var name: String, mut control: Float64):
        self.float64_dict[self.namespace + "." + name] = UnsafePointer[mut=True,Float64,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    # def add_control(mut self, var name: String, mut control: Float32):
    #     self.float32_dict[self.namespace + "." + name] = UnsafePointer[mut=True,Float32,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    def add_control(mut self, var name: String, mut control: Int):
        self.int_dict[self.namespace + "." + name] = UnsafePointer[mut=True,Int,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    # def add_trig_control(mut self, var name: String, mut control: Bool):
    #     self.trig_dict[self.namespace + "." + name] = UnsafePointer[mut=True,Bool,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    # def add_func(mut self, name: String, func: fn(values: List[Float64])):
    #     self.fn_dict[name] = func

    def retrieve_from_python(self) -> None:
        if self.world[].top_of_block():
            try:
                for fi in self.float64_dict.items():
                    # float64
                    fopt = self.world[].messenger_manager().get_float(fi.key)
                    if fopt:
                        fi.value[] = fopt.value()
                for fsi in self.floats64_dict.items():
                    # float64s
                    fsopt = self.world[].messenger_manager().get_floats(fsi.key)
                    if fsopt:
                        fsi.value[] = fsopt.value().copy()
                for ii in self.int_dict.items():
                    # int
                    iopt = self.world[].messenger_manager().get_int(ii.key)
                    if iopt:
                        ii.value[] = iopt.value()
                for bi in self.bool_dict.items():
                    # bool                    
                    bopt = self.world[].messenger_manager().get_bool(bi.key)
                    if bopt:
                        bi.value[] = bopt.value()
                for ti in self.trig_dict.items():
                    # triggers                    
                    ti.value[] = self.world[].messenger_manager().get_trig(ti.key)
                for si in self.strings_dict.items():
                    # strings
                    sopt = self.world[].messenger_manager().get_strings(si.key)
                    if sopt:
                        si.value[] = sopt.value().copy()
            except e:
                print("Error in ControlsHandler update: ", String(e))

    # =======================
    # ADD ALL THE CONTROLS
    # COLLECTED FROM A STRUCT
    # =======================

    # def add_controls(mut self, params: Tuple[
    #     Dict[String, UnsafePointer[mut=True,Float32,MutUntrackedOrigin]], # Float32
    #     Dict[String, UnsafePointer[mut=True,Float64,MutUntrackedOrigin]], # Float64
    #     Dict[String, UnsafePointer[mut=True,Int,MutUntrackedOrigin]], # Int
    #     Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]], # Bool
    #     Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]] # Trig
    # ]):
    #     for item in params[0].items():
    #         self.add_control(item.key, item.value[], cr)
    #     for item in params[1].items():
    #         self.add_control(item.key, item.value[], cr)
    #     for item in params[2].items():
    #         self.add_control(item.key, item.value[], cr)
    #     for item in params[3].items():
    #         self.add_control(item.key, item.value[], cr)
    #     for item in params[4].items():
    #         self.add_trig_control(item.key, item.value[], cr)
    #     self.initialized = True
    
    # =======================
    # COLLECT CONTROLS FROM A
    # STRUCT AND GET ALL THE
    # POINTERS OF "CONTROL" FIELDS
    # =======================

struct Float64Control(Movable,Copyable):
    var v: Float64
    var min: Float64
    var max: Float64
    var exponent: Float64
    var include_in_gui: Bool

    def __init__(out self, default: Float64, minimum: Float64 = 0.0, maximum: Float64 = 1.0, exponent: Float64 = 1.0, include_in_gui: Bool = True):
        self.v = default
        self.min = minimum
        self.max = maximum
        self.exponent = exponent
        self.include_in_gui = include_in_gui

    def set_normalized_value(mut self, normalized_input: Float64):
        new_val = (pow(normalized_input, self.exponent) * (self.max - self.min)) + self.min
        self.v = new_val

    def set_value(mut self, new_value: Float64):
        self.v = new_value

struct LagFloat64Control(Movable,Copyable):
    var v: Float64
    var world: World
    var float64control: Float64Control
    var lag: Lag[]

    def __init__(out self, world: World, default: Float64, lagtime: Float64, minimum: Float64 = 0.0, maximum: Float64 = 1.0, exponent: Float64 = 1.0, include_in_gui: Bool = True):
        self.world = world
        self.float64control = Float64Control(default,minimum,maximum,exponent,include_in_gui)
        self.v = self.float64control.v
        self.lag = Lag(self.world, lagtime)

    def next(mut self) -> Float64:
        self.v = self.lag.next(self.float64control.v)
        return self.v
    
    def set_normalized_value(mut self, normalized_input: Float64):
        self.float64control.set_normalized_value(normalized_input)

struct IntControl(Movable,Copyable):
    var v: Int
    var min: Int
    var max: Int
    var include_in_gui: Bool

    def __init__(out self, default: Int, minimum: Int = 0, maximum: Int = 1, include_in_gui: Bool = True):
        self.v = default
        self.min = minimum
        self.max = maximum
        self.include_in_gui = include_in_gui

struct BoolControl(Movable,Copyable):
    var v: Bool
    var include_in_gui: Bool

    def __init__(out self, default: Bool = False, include_in_gui: Bool = True):
        self.v = default
        self.include_in_gui = include_in_gui

struct EnvBoolControl(Movable,Copyable):
    var world: World
    var boolcontrol: BoolControl
    var env: ASREnv
    var ramp_time: Float64

    def __init__(out self, world: World, default: Bool = False, ramp_time: Float64 = 0.03, include_in_gui: Bool = True):
        self.world = world
        self.boolcontrol = BoolControl(default, include_in_gui)
        self.ramp_time = ramp_time
        self.env = ASREnv(self.world)

    def next(mut self) -> Float64:
        return self.env.next(self.ramp_time,1.0,self.ramp_time,self.boolcontrol.v)

struct TrigControl(Movable,Copyable):
    var v: Bool
    var include_in_gui: Bool

    def __init__(out self, default: Bool = False, include_in_gui: Bool = True):
        self.v = default
        self.include_in_gui = include_in_gui
    
    def next(mut self) -> Bool:
        if self.v:
            self.v = False
            return True
        return False

# struct KeyboardControl(Movable,Copyable):
#     var note: Float64
#     var velocity: Float64
#     var changeds: List[Changed[Float64]]
#     var include_in_gui: Bool

#     def __init__(out self, include_in_gui: Bool = True):
#         self.note = 0.0
#         self.velocity = 0.0
#         self.include_in_gui = include_in_gui

#         self.changeds = List[Changed[Float64]]()
#         self.changeds.append(Changed[Float64](self.note))
#         self.changeds.append(Changed[Float64](self.velocity))

#     def changed(mut self) -> Bool:
#         c = False
#         c |= self.changeds[0].next(self.note)
#         c |= self.changeds[1].next(self.velocity)
#         return c

#     def next(mut self) -> Bool: # bool indicates note on
#         if self.changed() and self.velocity > 0.0:
#             return True
#         return False