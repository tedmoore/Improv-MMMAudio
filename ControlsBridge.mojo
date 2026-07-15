from mmm_audio import *
from std.python import PythonObject, Python, ConvertibleFromPython
from std.python.bindings import PythonModuleBuilder
from std.reflection import *
from std.sys.intrinsics import _type_is_eq
from instrument.Instrument import *
from instrument.Instrument_Synths import *
from instrument.SpearPlayer_Module import *
from instrument.WarmTones_Module import *
from std.os import abort

# Currently, this needs to be edited so that it contains
# all the structs that I want to expose the controls of
def get_controls() -> PythonObject:
    print("Collecting control parameters from Mojo...")
    try:
        w = alloc[MMMWorld](1)
        w.init_pointee_move(MMMWorld(48000))
        
        # a dict for eventually passing things out
        dict = Python.dict()

        # get controls for the main Instrument struct
        instr = Instrument(w)
        get_controls_from_struct(instr, dict)

        dict["num_mlps"] = instr.mlp_manager.n_mlps
        dict["mlp_max_inputs"] = instr.mlp_manager.max_inputs

        # get controls from the modules
        dict["modules"] = Python.dict()

        sc = SampColl(w)
        get_controls_from_struct(sc, dict["modules"])
        ph = Phasey(w)
        get_controls_from_struct(ph, dict["modules"])
        fin = FIN(w)
        get_controls_from_struct(fin, dict["modules"])
        b = Benjolin(w)
        get_controls_from_struct(b, dict["modules"])
        sampspace = SampleSpace(w)
        get_controls_from_struct(sampspace, dict["modules"])
        spearplayer = SpearPlayer(w)
        get_controls_from_struct(spearplayer, dict["modules"])
        warmtones = WarmTones(w)
        get_controls_from_struct(warmtones, dict["modules"])
        pshiftdel = PShiftDel(w)
        get_controls_from_struct(pshiftdel, dict["modules"])
        fg = FilterGlitch(w)
        get_controls_from_struct(fg, dict["modules"])
        sttr = Stutter(w)
        get_controls_from_struct(sttr, dict["modules"])
        fbd = FBDelay(w)
        get_controls_from_struct(fbd, dict["modules"])
        spfr = SpecFreeze(w)
        get_controls_from_struct(spfr, dict["modules"])
        spsm = SpectralSmear(w)
        get_controls_from_struct(spsm, dict["modules"])
        chromasus = ChromaSus(w)
        get_controls_from_struct(chromasus, dict["modules"])
        sq = Squiz(w)
        get_controls_from_struct(sq, dict["modules"])
        lpf = LPFilter(w)
        get_controls_from_struct(lpf, dict["modules"])
        looper = Looper(w)
        get_controls_from_struct(looper, dict["modules"])
        chr = Chorus(w)
        get_controls_from_struct(chr, dict["modules"])
        rev = Reverb(w)
        get_controls_from_struct(rev, dict["modules"])
        am = AmpMod(w)
        get_controls_from_struct(am, dict["modules"])
        compress = Compress(w)
        get_controls_from_struct(compress, dict["modules"])
        softclip = SoftClip(w)
        get_controls_from_struct(softclip, dict["modules"])
        hardclip = HardClip(w)
        get_controls_from_struct(hardclip, dict["modules"])
        tanh = Tanh(w)
        get_controls_from_struct(tanh, dict["modules"])

        # order that the modules are listed in the Instrument fields
        # is the order they'll be displayed in 
        get_module_order_from_Instrument(dict)

        return dict
    except err:
        print("Error printing field types: ",String(err))
        return None

def get_module_order_from_Instrument(dict: PythonObject) raises:

    comptime types = reflect[Instrument].field_types()

    dict["module_order"] = Python.list()

    comptime for i in range(reflect[Instrument].field_count()):
        typename: String = reflect[types[i]].name()
        if typename.__contains__("ModuleWrapper"):
            sub = typename.split("Instrument_Synths.")
            idx = sub.__len__() - 1
            last = sub[idx]
            name = last.split(", ")[0]
            dict["module_order"].append(name)

def get_controls_from_struct[T: AnyType](stru: T, maindict: PythonObject) raises:
    comptime types = reflect[T].field_types()
    comptime names = reflect[T].field_names()
    comptime structname = reflect[T].base_name()
    dict = Python.dict()
    dict["params"] = Python.list()

    comptime if conforms_to(T, Modulable):
        ref t = trait_downcast[Modulable](stru)
        dict["namespace"] = t.get_namespace()
    else:
        dict["namespace"] = None

    comptime for i in range(reflect[T].field_count()):
        name = materialize[names[i]]()

        # if _type_is_eq[types[i], Float32Control]():
        #     ref fp = __struct_field_ref(i, stru)
        #     ref fp_param = rebind[Float32Control](fp)
        #     if fp_param.include_in_gui:
        #         pdict = Python.dict()
        #         pdict["name"] = name
        #         pdict["type"] = "float"
        #         pdict["default"] = fp_param.v
        #         pdict["min"] = fp_param.min
        #         pdict["max"] = fp_param.max
        #         pdict["exponent"] = fp_param.exponent
        #         dict["params"].append(pdict)

        if _type_is_eq[types[i], Float64Control]():
            ref fp = __struct_field_ref(i, stru)
            ref fp_param = rebind[Float64Control](fp)
            if fp_param.include_in_gui:
                pdict = Python.dict()
                pdict["name"] = name
                pdict["type"] = "float"
                pdict["default"] = fp_param.v
                pdict["min"] = fp_param.min
                pdict["max"] = fp_param.max
                pdict["exponent"] = fp_param.exponent
                dict["params"].append(pdict)
        
        elif _type_is_eq[types[i], LagFloat64Control]():
            ref fp = __struct_field_ref(i, stru)
            ref fp_param = rebind[LagFloat64Control](fp)
            if fp_param.float64control.include_in_gui:
                pdict = Python.dict()
                pdict["name"] = name
                pdict["type"] = "float"
                pdict["default"] = fp_param.float64control.v
                pdict["min"] = fp_param.float64control.min
                pdict["max"] = fp_param.float64control.max
                pdict["exponent"] = fp_param.float64control.exponent
                dict["params"].append(pdict)

        elif _type_is_eq[types[i], IntControl]():
            ref ip = __struct_field_ref(i, stru)
            ref ip_param = rebind[IntControl](ip)
            if ip_param.include_in_gui:
                pdict = Python.dict()
                pdict["name"] = name
                pdict["type"] = "int"
                pdict["default"] = ip_param.v
                pdict["min"] = ip_param.min
                pdict["max"] = ip_param.max
                dict["params"].append(pdict)

        elif _type_is_eq[types[i], BoolControl]():
            ref bp = __struct_field_ref(i, stru)
            ref bp_param = rebind[BoolControl](bp)
            if bp_param.include_in_gui:
                pdict = Python.dict()
                pdict["name"] = name
                pdict["type"] = "bool"
                pdict["default"] = bp_param.v
                dict["params"].append(pdict)

        elif _type_is_eq[types[i], TrigControl]():
            ref tp = __struct_field_ref(i, stru)
            ref tp_param = rebind[TrigControl](tp)
            if tp_param.include_in_gui:
                pdict = Python.dict()
                pdict["name"] = name
                pdict["type"] = "trig"
                pdict["default"] = tp_param.v
                dict["params"].append(pdict)
    
    basename_py = Python.str(structname)
    maindict[basename_py] = dict

@export
def PyInit_ControlsBridge() abi("C") -> PythonObject:
    try:
        var m = PythonModuleBuilder("ControlsBridge")
        m.def_function[get_controls]("get_controls")
        return m.finalize()
    except e:
        abort(String("error creating Python Mojo module:", e))