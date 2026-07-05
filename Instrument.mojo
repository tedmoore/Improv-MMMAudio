from mmm_audio import *
from instrument.Instrument_Synths import *
from instrument.MatrixMixer_module import *
from instrument.ControlsHandler_module import *
from std.reflection import *
from std.sys.intrinsics import _type_is_eq

comptime neg130db = dbamp(-130.0)

@fieldwise_init
struct LFOType(Equatable, ImplicitlyCopyable):
    var _value: Int

    comptime sine = LFOType(0)
    comptime triangle = LFOType(1)
    comptime saw = LFOType(2)
    comptime square = LFOType(3)
    # comptime noise = LFOType(4)

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

struct LFO(Copyable, Movable):
    var world: World
    var freq: Float64
    var min: Float64
    var max: Float64
    var exponent: Float64
    var type: LFOType
    var osc: Osc[]
    var v: Float64
    var ptr: Optional[UnsafePointer[mut=True,Float64,MutUntrackedOrigin]]

    def __init__(out self, world: World):
        self.world = world
        self.freq = 1.0
        self.min = 0.0
        self.max = 1.0
        self.exponent = 1.0
        self.type = LFOType.sine
        self.osc = Osc(world)
        self.v = 0.0
        # if the ptr is not None then this LFO is active, if the ptr is None then this LFO is inactive
        self.ptr = Optional[UnsafePointer[mut=True,Float64,MutUntrackedOrigin]](None)

    @staticmethod
    def exponent_warp(x: Float64, inmin: Float64, inmax: Float64, outmin: Float64, outmax: Float64, exponent: Float64) -> Float64:
        # normalize to 0-1
        norm = (x - inmin) / (inmax - inmin)
        # apply exponent warp
        warped = norm ** exponent
        # scale to output range
        return warped * (outmax - outmin) + outmin

    def next(mut self):

        if not self.ptr:
            return

        if self.type == LFOType.sine:
            self.v = LFO.exponent_warp(self.osc.next[osc_type=OscType.sine](self.freq), -1.0, 1.0, self.min, self.max, self.exponent)
        elif self.type == LFOType.triangle:
            self.v = LFO.exponent_warp(self.osc.next[osc_type=OscType.triangle](self.freq), -1.0, 1.0, self.min, self.max, self.exponent)
        elif self.type == LFOType.saw:
            self.v = LFO.exponent_warp(self.osc.next[osc_type=OscType.saw](self.freq), 0.0, 1.0, self.min, self.max, self.exponent)
        elif self.type == LFOType.square:
            self.v = LFO.exponent_warp(self.osc.next[osc_type=OscType.square](self.freq), -1.0, 1.0, self.min, self.max, self.exponent)

        self.v = sanitize(self.v)
        self.v = clip(self.v, self.min, self.max)

        self.ptr.value()[] = self.v

struct LFOManager(Copyable, Movable):
    comptime n_lfos: Int = 16
    var world: World
    var lfos: InlineArray[LFO, Self.n_lfos]
    var ch: ControlsHandler
    var lfo_details: List[String]
    var deactivate_idx: Int
    var initialized: Bool

    def __init__(out self, world: World):
        self.world = world
        self.lfos = InlineArray[LFO, Self.n_lfos](fill=LFO(world))
        self.ch = ControlsHandler(world, "lfo_manager")
        self.lfo_details = List[String]()
        self.deactivate_idx = -1
        self.initialized = False

    def assign_lfo(mut self, cr: ControlsRegistry, idx: Int, id: String, min: Float64, max: Float64, exponent: Float64):
        ptr = cr.float64_dict.get(id)
        if ptr:
            self.lfos[idx].min = min
            self.lfos[idx].max = max
            self.lfos[idx].exponent = exponent
            self.lfos[idx].ptr = ptr.value()
        else:
            print("Error: No control found for id: ", id)

    def next(mut self, mut cr: ControlsRegistry):

        if not self.initialized:
            for i in range(Self.n_lfos):
                cr.register("lfo." + String(i) + ".freq", self.lfos[i].freq)
            self.initialized = True

        if self.ch.notify_update("lfo_manager.assign", self.lfo_details):
            if len(self.lfo_details) != 5:
                print("Error: Invalid number of arguments for new LFO")
            else:
                try:
                    idx = Int(self.lfo_details[0])
                    id = self.lfo_details[1]
                    min = Float64(self.lfo_details[2])
                    max = Float64(self.lfo_details[3])
                    exponent = Float64(self.lfo_details[4])
                    self.assign_lfo(cr, idx, id, min, max, exponent)
                except e:
                    print("Error adding new LFO: ", String(e))

        if self.ch.notify_update("lfo_manager.deactivate", self.deactivate_idx):
            if self.deactivate_idx < 0 or self.deactivate_idx >= Self.n_lfos:
                print("LFOManager: Error: deactivate_idx out of range: ", self.deactivate_idx)
            else:
                self.lfos[self.deactivate_idx].ptr = None

        for i in range(Self.n_lfos):
            lfo_type = self.lfos[i].type._value
            if self.ch.notify_update("lfo_manager." + String(i) + ".type", lfo_type):
                if lfo_type == 0:
                    self.lfos[i].type = LFOType.sine
                elif lfo_type == 1:
                    self.lfos[i].type = LFOType.triangle
                elif lfo_type == 2:
                    self.lfos[i].type = LFOType.saw
                elif lfo_type == 3:
                    self.lfos[i].type = LFOType.square
                else:
                    print("LFOManager: Error: invalid LFO type: ", lfo_type)

            freq = self.lfos[i].freq
            if self.ch.notify_update("lfo_manager." + String(i) + ".freq", freq):
                self.lfos[i].freq = freq

        for ref lfo in self.lfos:
            lfo.next()

trait Modulable(Copyable, Movable, ImplicitlyDestructible):
    def next(mut self, mut cr: ControlsRegistry, input: MFloat[2] = 0.0) -> MFloat[2]:...
    def get_namespace(self) -> String:...

struct ModuleWrapper[T:Modulable,keep_running:Bool=False](Movable, Copyable):
    var world: World
    var module: Self.T
    var vol: LagFloat64Control
    var mix: LagFloat64Control
    var bypass: BoolControl
    var bypass_lag: Lag[]
    var stop: BoolControl
    var stop_lag: Lag[]
    var matrix_mixer_indicates_being_used: Bool
    var matmix_lag: Lag[]

    def __init__(out self, world: World, var module: Self.T):
        self.world = world
        self.vol = LagFloat64Control(self.world,0.0, 0.03, -130.0, 0, 8)
        self.mix = LagFloat64Control(self.world,1.0, 0.03, 0, 1)
        self.bypass = BoolControl(False)
        self.bypass_lag = Lag(self.world, 0.03)
        self.stop = BoolControl(False)
        self.stop_lag = Lag(self.world, 0.03)
        self.module = module^
        self.matrix_mixer_indicates_being_used = False
        self.matmix_lag = Lag(self.world, 0.03)

    def next_from_matmix(mut self, input: Tuple[MFloat[2],Bool], mut cr: ControlsRegistry) -> MFloat[2]:
        self.matrix_mixer_indicates_being_used = input[1]
        return self.next(cr, input[0])

    def lazy_initialization(mut self, mut cr: ControlsRegistry):
        cr.register_controls(self, self.module.get_namespace() + ".mw")
        cr.register_controls(self.module, self.module.get_namespace())
        _ = self.module.next(cr, 0.0)  # Call next once to ensure any internal state is initialized

    def next(mut self, mut cr: ControlsRegistry, var input: MFloat[2] = 0.0) -> MFloat[2]:

        input = sanitize(input)

        stop_env: Float64 = self.stop_lag.next(0.0 if self.stop.v else 1.0)
        bypass_env: Float64 = self.bypass_lag.next(0.0 if self.bypass.v else 1.0)
        matmix_env: Float64 = self.matmix_lag.next(0.0 if self.matrix_mixer_indicates_being_used else 1.0)
        mixv = self.mix.next()
        volv = self.vol.next()

        comptime if not Self.keep_running:
            if stop_env < neg130db or (1-matmix_env) < neg130db:
                return 0.0
            
            if bypass_env < neg130db:
                return input * dbamp(volv) * stop_env

        out = sanitize(self.module.next(cr, input))
        out = select(mixv, input, out)
        out = select(bypass_env, input, out)
        out *= dbamp(volv)
        out *= 1 - matmix_env
        out *= stop_env
        return out

struct ControlsRegistry(Movable,Copyable):
    var world: World
    # var float32_dict: Dict[String, UnsafePointer[mut=True,Float32,MutUntrackedOrigin]]
    # var float32control_dict: Dict[String, UnsafePointer[mut=True,Float32Control,MutUntrackedOrigin]]
    var float64_dict: Dict[String, UnsafePointer[mut=True,Float64,MutUntrackedOrigin]]
    var float64control_dict: Dict[String, UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin]]
    var float64s_dict: Dict[String, UnsafePointer[mut=True,List[Float64],MutUntrackedOrigin]]
    var int_dict: Dict[String, UnsafePointer[mut=True,Int,MutUntrackedOrigin]]
    var bool_dict: Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]
    var trig_dict: Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]
    # var fn_dict: Dict[String, fn(values: List[Float64])]

    def __init__(out self, world: World):
        self.world = world
        # self.float32_dict = Dict[String, UnsafePointer[mut=True,Float32,MutUntrackedOrigin]]()
        # self.float32control_dict = Dict[String, UnsafePointer[mut=True,Float32Control,MutUntrackedOrigin]]()
        self.float64_dict = Dict[String, UnsafePointer[mut=True,Float64,MutUntrackedOrigin]]()
        self.float64control_dict = Dict[String, UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin]]()
        self.float64s_dict = Dict[String, UnsafePointer[mut=True,List[Float64],MutUntrackedOrigin]]()
        self.int_dict = Dict[String, UnsafePointer[mut=True,Int,MutUntrackedOrigin]]()
        self.bool_dict = Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]()
        self.trig_dict = Dict[String, UnsafePointer[mut=True,Bool,MutUntrackedOrigin]]()
        # self.fn_dict = Dict[String, fn(values: List[Float64])]()

    def retrieve_from_python(self) -> None:
        if self.world[].top_of_block():
            try:
                for fi in self.float64_dict.items():
                    # float64
                    fopt = self.world[].messenger_manager().get_float(fi.key)
                    if fopt:
                        fi.value[] = fopt.value()

                # for fi32 in self.float32_dict.items():
                #     # float32
                #     f32opt = self.world[].messenger_manager().get_float(fi32.key)
                #     if f32opt:
                #         fi32.value[] = Float32(f32opt.value())

                for fi64c in self.float64control_dict.items():
                    # float64control
                    f64copt = self.world[].messenger_manager().get_float(fi64c.key)
                    if f64copt:
                        fi64c.value[].set_value(f64copt.value())

                # for fi32c in self.float32control_dict.items():
                #     # float32control
                #     f32copt = self.world[].messenger_manager().get_float(fi32c.key)
                #     if f32copt:
                #         fi32c.value[].set_value(Float32(f32copt.value()))
                
                for fsi in self.float64s_dict.items():
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
            except e:
                print("Error in ControlsHandler update: ", String(e))

    # Register a Float64
    def register(mut self, var name: String, mut control: Float64):
        self.float64_dict[name] = UnsafePointer[mut=True,Float64,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    # Register a Float64Control
    def register(mut self, var name: String, mut control: Float64Control):
        self.float64control_dict[name] = UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=control)))

    # Register a LagFloat64Control
    def register(mut self, var name: String, mut control: LagFloat64Control):
        self.register(name, control.float64control)

    def register_controls[T:AnyType,//](mut self, host: T, namespace: String):
        comptime types = reflect[T].field_types()
        comptime names = reflect[T].field_names()
        comptime for i in range(reflect[T].field_count()):

            # if _type_is_eq[types[i], Float32Control]():
            #     name = namespace + "." + String(materialize[names[i]]())
            #     ref fp = __struct_field_ref(i, host)
            #     ref fpr = rebind[Float32Control](fp)
            #     self.float32control_dict[name] = UnsafePointer[mut=True,Float32Control,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=fpr)))
            
            if _type_is_eq[types[i], Float64Control]():
                name = namespace + "." + String(materialize[names[i]]())
                ref fp = __struct_field_ref(i, host)
                ref fpr = rebind[Float64Control](fp)
                self.float64control_dict[name] = UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=fpr)))
            
            elif _type_is_eq[types[i], LagFloat64Control]():
                name = namespace + "." + String(materialize[names[i]]())
                ref lfp = __struct_field_ref(i, host)
                ref lfpr = rebind[LagFloat64Control](lfp)
                self.float64control_dict[name] = UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=lfpr.float64control)))
            
            elif _type_is_eq[types[i], IntControl]():
                name = namespace + "." + String(materialize[names[i]]())
                ref ip = __struct_field_ref(i, host)
                ref ipr = rebind[IntControl](ip)
                self.int_dict[name] = UnsafePointer[Int,MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=ipr)))
            
            elif _type_is_eq[types[i], BoolControl]():
                name = namespace + "." + String(materialize[names[i]]())
                ref bp = __struct_field_ref(i, host)
                ref bpr = rebind[BoolControl](bp)
                self.bool_dict[name] = UnsafePointer[Bool, MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=bpr.v)))
            
            elif _type_is_eq[types[i], TrigControl]():
                name = namespace + "." + String(materialize[names[i]]())
                ref tp = __struct_field_ref(i, host)
                ref tpr = rebind[TrigControl](tp)
                self.trig_dict[name] = UnsafePointer[Bool, MutUntrackedOrigin](unsafe_from_address=Int(UnsafePointer(to=tpr.v)))
        
struct TestInputFile(Movable,Copyable):
    var path: String
    var buf: SIMDBuffer[1]
    var loaded: Bool
    var player: Play

    def __init__(out self, world: World):
        self.path = ""
        self.loaded = False
        self.buf = SIMDBuffer[1].zeros(0)
        self.player = Play(world)
    
    def load(mut self):
        self.buf = SIMDBuffer[1].load(self.path)
        self.loaded = True
    
    def next(mut self) -> MFloat[2]:
        if self.loaded:
            return self.player.next(self.buf)
        else:
            return 0.0

struct MLPControl[max_inputs: Int = 10](Movable,Copyable):
    var world: World
    var output_ids: List[String]
    var model_file_path: String
    var torch: PythonObject
    var np: PythonObject
    var model: PythonObject
    var active: Bool
    var output_ptrs: List[UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin]]
    var impulse: Impulse[]
    var trig_freq: Float64
    var received_inputs: InlineArray[Float64, Self.max_inputs]
    var py_tensor_inputs: PythonObject
    var py_tensor_outputs: PythonObject
    var ch: ControlsHandler
    var mlp_id_int: Int
    var received_outputs_norm: List[Float64]
    var model_loaded: Bool
    var output_ids_string: String
    var outputs_norm_string: String
    var n_inputs: Int
    var output_lags: List[Lag[]]
    var output_values: List[Float64]

    def __init__(out self, world: World, mlp_id_int: Int):
        self.world = world
        self.mlp_id_int = mlp_id_int
        self.active = False
        self.model_loaded = False
        self.model_file_path = ""
        self.torch = PythonObject(None)
        self.model = PythonObject(None)
        self.impulse = Impulse[](world)
        self.trig_freq = 30.0
        self.py_tensor_inputs = PythonObject(None)
        self.received_inputs = InlineArray[Float64, Self.max_inputs](fill=0.0)
        self.received_outputs_norm = List[Float64]()
        self.py_tensor_outputs = PythonObject(None)
        self.np = PythonObject(None)
        self.ch = ControlsHandler(world, "mlp." + String(self.mlp_id_int))
        self.output_ptrs = List[UnsafePointer[mut=True,Float64Control,MutUntrackedOrigin]]()
        self.output_ids = List[String]()
        self.output_ids_string = "mlp." + String(self.mlp_id_int) + ".output_ids"
        self.outputs_norm_string = "mlp." + String(self.mlp_id_int) + ".outputs_norm"
        self.n_inputs = 0
        self.output_lags = List[Lag[]]()
        self.output_values = List[Float64]()

        # import torch
        try:
            self.torch = Python.import_module("torch")
        except e:
            abort("Error importing torch module: " + String(e))
        
        # import numpy
        try:
            self.np = Python.import_module("numpy")
        except e:
            abort("Error importing numpy module: " + String(e))

    def load_mlp(mut self, cr: ControlsRegistry):
        try:
            # load model
            self.model = self.torch.jit.load(self.model_file_path)
            self.model.eval()
            for _ in range (5):
                self.model(self.torch.randn(1, self.n_inputs))
            print("Torch model loaded successfully")

            # prepare numpy input values
            self.py_tensor_inputs = self.torch.zeros(1, self.n_inputs) # 2D tensor with shape (1, n_inputs) filled with zeros

            # prepare numpy output values (here just because it's in a try...)
            self.py_tensor_outputs = self.torch.zeros(1,len(self.output_ids)) # 2D tensor with shape (1, num_outputs) filled with zeros

            self.model_loaded = True
        except e:
            print("Error loading MLP model: ", String(e))
            self.model_loaded = False

    def populate_output_ptrs_from_output_ids(mut self, cr: ControlsRegistry):
        # repopulate pointers
        self.output_ptrs.clear()
        for id in self.output_ids:
            ptr = cr.float64control_dict.get(id)
            if ptr:
                self.output_ptrs.append(ptr.value())
            else:
                print("Warning: No control found for output id: ", id)

        # resize lags
        while len(self.output_lags) < len(self.output_ptrs):
            self.output_lags.append(Lag[](self.world, 1.0 / self.trig_freq))
        while len(self.output_lags) > len(self.output_ptrs):
            _ = self.output_lags.pop()

        self.output_values = List[Float64](length=len(self.output_ptrs),fill=0.0)

        # this doesn't need to be resized or anything because 
        # it all gets updated in one fell swoop anyway
        self.received_outputs_norm.clear()

    def next(mut self, cr: ControlsRegistry):

        # INITIALIZE ALL CONTROLS
        if not self.ch.initialized:
            for i in range(Self.max_inputs):
                self.ch.add_control("input." + String(i), self.received_inputs[i])
            self.ch.add_control("trig_freq", self.trig_freq)
            self.ch.add_control("active", self.active)
            self.ch.add_control("n_inputs", self.n_inputs)
            self.ch.initialized = True

        # CHECK IF THERE ARE NEW CONTROLS FROM PYTHON
        self.ch.retrieve_from_python()

        # check if a new model has been sent
        if self.ch.notify_update("mlp." + String(self.mlp_id_int) + ".load_model", self.model_file_path):
            self.load_mlp(cr)

        # check if some values have been sent that need to be sent to the pointers
        if self.ch.notify_update(self.outputs_norm_string, self.received_outputs_norm):
            for i in range(len(self.received_outputs_norm)):
                if i < len(self.output_ptrs):
                    self.output_ptrs[i][].set_normalized_value(self.received_outputs_norm[i])
                else:
                    print("Warning: output_ptrs index out of range for number of .outputs_norm received from MLP model")
        
        # check if new output ids have been sent that need to update the output_ptrs
        if self.ch.notify_update(self.output_ids_string, self.output_ids):
            self.populate_output_ptrs_from_output_ids(cr)



        if self.active:
            if  self.model_loaded and self.impulse.next_bool(self.trig_freq): # TODO: also check whether the inputs have changed
                # print("Running MLP model with inputs: ", self.received_inputs)
                # print("len of output_ptrs: ", len(self.output_ptrs))
                # print("len of output_values: ", len(self.output_values))
                # print("len of output_lags: ", len(self.output_lags))
                # print("len of received_outputs_norm: ", len(self.received_outputs_norm))
                # print("len of output_ids: ", len(self.output_ids))
                try:
                    # print("len of py_tensor_inputs: ", len(self.py_tensor_inputs[0])) # [0] because the input is a 2D tensor with shape (1, num_inputs)
                    # print("len of py_tensor_outputs: ", len(self.py_tensor_outputs[0])) # [0] because the output is a 2D tensor with shape (1, num_outputs)
                    for i in range(len(self.py_tensor_inputs[0])): # [0] because the input is a 2D tensor with shape (1, num_inputs)
                        self.py_tensor_inputs[0][i] = self.received_inputs[i] # [0] because the input is a 2D tensor with shape (1, num_inputs)

                    self.py_tensor_outputs = self.model(self.py_tensor_inputs)

                    for i in range(len(self.output_values)):
                        if i < len(self.py_tensor_outputs[0]): # [0] because the output is a 2D tensor with shape (1, num_outputs)

                            # set the input value so that when the next() function is called, it will lag towards this value
                            self.output_lags[i].input = Float64(py=self.py_tensor_outputs[0][i].item()) # [0] because the output is a 2D tensor with shape (1, num_outputs)
                        else:
                            print("Warning: output_values index out of range for number of outputs received from MLP model")
                except e:
                    print("Error running MLP model", String(e))

                # print("output_values: ", self.output_values)

            # UPDATE POINTERS
            for i in range(len(self.output_ptrs)):
                if i < len(self.output_values):
                    self.output_values[i] = self.output_lags[i].next()
                    # self.world[].print("Setting output_ptrs[", i, "] to ", self.output_values[i])
                    self.output_ptrs[i][].set_normalized_value(self.output_values[i])
                else:
                    print("Warning: output_ptrs index out of range for number of output_values")

struct MLPManager[n_mlps: Int = 8,max_inputs: Int = 10](Movable,Copyable):
    var mlps: List[MLPControl[Self.max_inputs]]

    def __init__(out self, world: World):
        self.mlps = List[MLPControl[Self.max_inputs]]()
        for i in range(Self.n_mlps):
            self.mlps.append(MLPControl[Self.max_inputs](world, i))

    def next(mut self, cr: ControlsRegistry):

        for ref mlp in self.mlps:
            mlp.next(cr)
    
struct Instrument(Movable,Copyable):
    comptime num_inputs: Int = 1
    var world: World
    var cr: ControlsRegistry
    var ch: ControlsHandler
    var vol: LagFloat64Control
    var matmix: InstrumentMatrixMixer
    var lfo_manager: LFOManager
    var mlp_manager: MLPManager[8,10]
    var test_input_file: TestInputFile

    var sampcoll: ModuleWrapper[SampColl]
    var phasey: ModuleWrapper[Phasey]
    var fin: ModuleWrapper[FIN]
    var benjolin: ModuleWrapper[Benjolin]
    var sample_space: ModuleWrapper[SampleSpace]
    var filterglitch: ModuleWrapper[FilterGlitch]
    var stutter: ModuleWrapper[Stutter]
    var fbdelay: ModuleWrapper[FBDelay,True]
    var spectral_freeze: ModuleWrapper[SpecFreeze,True]
    var spectral_smear: ModuleWrapper[SpectralSmear]
    var chroma_sus: ModuleWrapper[ChromaSus]
    var squiz: ModuleWrapper[Squiz]
    var lpf: ModuleWrapper[LPFilter]
    var chorus: ModuleWrapper[Chorus,True]
    var reverb: ModuleWrapper[Reverb,True]
    var ampmod: ModuleWrapper[AmpMod]
    var compress: ModuleWrapper[Compress]
    var softclip: ModuleWrapper[SoftClip]
    comptime num_modules: Int = 18

    def __init__(out self, world: World):
        self.world = world
        self.vol = LagFloat64Control(self.world,-130.0, 0.03, -130.0, 0, 0.125)
        self.ch = ControlsHandler(self.world, "instrument")
        var output_to_downstream = List[Int]()

        for i in range(Self.num_modules):
            output_to_downstream.append(i + Self.num_inputs)  # output i feeds input i + num_inputs
        output_to_downstream.append(-1)  # speaker output has no downstream

        self.matmix = InstrumentMatrixMixer(
            num_inputs=Self.num_modules + Self.num_inputs,
            num_outputs=Self.num_modules + 1, # just one stereo output
            speaker_output_idx=Self.num_modules,
            output_to_downstream_input=output_to_downstream
        )

        self.test_input_file = TestInputFile(self.world)

        self.cr = ControlsRegistry(self.world)
        self.lfo_manager = LFOManager(self.world)
        self.mlp_manager = MLPManager[8,10](self.world)

        self.sampcoll = ModuleWrapper(self.world, SampColl(self.world))
        self.phasey = ModuleWrapper[Phasey](self.world, Phasey(self.world))
        self.fin = ModuleWrapper(self.world, FIN(self.world))
        self.benjolin = ModuleWrapper(self.world, Benjolin(self.world))
        self.sample_space = ModuleWrapper(self.world, SampleSpace(self.world,"instrument/resources/SampleSpace_shoe-squeak.json"))
        self.filterglitch = ModuleWrapper(self.world, FilterGlitch(self.world))
        self.stutter = ModuleWrapper(self.world, Stutter(self.world))
        self.fbdelay = ModuleWrapper[FBDelay,True](self.world, FBDelay(self.world))
        self.spectral_freeze = ModuleWrapper[SpecFreeze,True](self.world, SpecFreeze(self.world))
        self.spectral_smear = ModuleWrapper[SpectralSmear](self.world, SpectralSmear(self.world))
        self.chroma_sus = ModuleWrapper[ChromaSus](self.world, ChromaSus(self.world))
        self.squiz = ModuleWrapper[Squiz](self.world, Squiz(self.world))
        self.lpf = ModuleWrapper[LPFilter](self.world, LPFilter(self.world))
        self.chorus = ModuleWrapper[Chorus,True](self.world, Chorus(self.world))
        self.reverb = ModuleWrapper[Reverb,True](self.world, Reverb(self.world))
        self.ampmod = ModuleWrapper[AmpMod](self.world, AmpMod(self.world))
        self.compress = ModuleWrapper(self.world, Compress(self.world))
        self.softclip = ModuleWrapper(self.world, SoftClip(self.world))
        
    def next(mut self) -> MFloat[2]:

        # INITIALIZE ALL CONTROLS
        if not self.ch.initialized:
            self.cr.register("instrument.vol", self.vol)
            self.sampcoll.lazy_initialization(self.cr)
            self.phasey.lazy_initialization(self.cr)
            self.fin.lazy_initialization(self.cr)
            self.benjolin.lazy_initialization(self.cr)
            self.sample_space.lazy_initialization(self.cr)
            self.filterglitch.lazy_initialization(self.cr)
            self.stutter.lazy_initialization(self.cr)
            self.fbdelay.lazy_initialization(self.cr)
            self.spectral_freeze.lazy_initialization(self.cr)
            self.spectral_smear.lazy_initialization(self.cr)
            self.chroma_sus.lazy_initialization(self.cr)
            self.squiz.lazy_initialization(self.cr)
            self.lpf.lazy_initialization(self.cr)
            self.chorus.lazy_initialization(self.cr)
            self.reverb.lazy_initialization(self.cr)
            self.ampmod.lazy_initialization(self.cr)
            self.compress.lazy_initialization(self.cr)
            self.softclip.lazy_initialization(self.cr)
            self.ch.initialized = True

        # RETRIEVE ALL CONTROLS
        self.cr.retrieve_from_python()
        # self.ch.retrieve_from_python()
        if self.ch.notify_update("instrument.matrix_mixer_coeffs", self.matmix.coeffs):
            self.matmix.update_is_used()
        
        if self.ch.notify_update("instrument.test_input_file", self.test_input_file.path):
            if Path(self.test_input_file.path).exists():
                self.test_input_file.load()

        self.lfo_manager.next(self.cr)

        self.mlp_manager.next(self.cr)

        # RUN DSP GRAPH
        if self.test_input_file.loaded:
            mic0 = self.test_input_file.next()
        else:
            mic0 = MFloat[2](self.world[].sound_in(0))

        # TODO: figure out how to get these in a list so i can iterate
        self.matmix.provide_input(0, mic0)
        self.matmix.provide_input(1,self.sampcoll.next_from_matmix(self.matmix.get_output_check_used(0, 1), self.cr))
        self.matmix.provide_input(2,self.phasey.next_from_matmix(self.matmix.get_output_check_used(1, 2), self.cr))
        self.matmix.provide_input(3,self.fin.next_from_matmix(self.matmix.get_output_check_used(2, 3), self.cr))
        self.matmix.provide_input(4,self.benjolin.next_from_matmix(self.matmix.get_output_check_used(3, 4), self.cr))
        self.matmix.provide_input(5,self.sample_space.next_from_matmix(self.matmix.get_output_check_used(4, 5), self.cr))
        self.matmix.provide_input(6,self.filterglitch.next_from_matmix(self.matmix.get_output_check_used(5, 6), self.cr))
        self.matmix.provide_input(7,self.stutter.next_from_matmix(self.matmix.get_output_check_used(6, 7), self.cr))
        self.matmix.provide_input(8,self.fbdelay.next_from_matmix(self.matmix.get_output_check_used(7, 8), self.cr))
        self.matmix.provide_input(9,self.spectral_freeze.next_from_matmix(self.matmix.get_output_check_used(8, 9), self.cr))
        self.matmix.provide_input(10,self.spectral_smear.next_from_matmix(self.matmix.get_output_check_used(9, 10), self.cr))
        self.matmix.provide_input(11,self.chroma_sus.next_from_matmix(self.matmix.get_output_check_used(10, 11), self.cr))
        self.matmix.provide_input(12,self.squiz.next_from_matmix(self.matmix.get_output_check_used(11, 12), self.cr))
        self.matmix.provide_input(13,self.lpf.next_from_matmix(self.matmix.get_output_check_used(12, 13), self.cr))
        self.matmix.provide_input(14,self.chorus.next_from_matmix(self.matmix.get_output_check_used(13, 14), self.cr))
        self.matmix.provide_input(15,self.reverb.next_from_matmix(self.matmix.get_output_check_used(14, 15), self.cr))
        self.matmix.provide_input(16,self.ampmod.next_from_matmix(self.matmix.get_output_check_used(15, 16), self.cr))
        self.matmix.provide_input(17,self.compress.next_from_matmix(self.matmix.get_output_check_used(16, 17), self.cr))
        self.matmix.provide_input(18,self.softclip.next_from_matmix(self.matmix.get_output_check_used(17, 18), self.cr))

        if self.vol.next() > -130.0:
            out = self.matmix.get_output(Self.num_modules) * dbamp(self.vol.v)
            return out
        else:
            return 0.0
