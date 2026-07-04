from mmm_audio import *
from std.python import PythonObject, Python

struct TorchNN(Copyable, Movable): 
    var world: World
    var py_input: PythonObject  
    var py_output: PythonObject  
    var model: PythonObject  
    var torch: PythonObject  
    var input_size: Int
    var output_size: Int
    var model_path: String

    def __init__(out self, world: World, input_size: Int, output_size: Int, model_path: String):
        self.world = world
        self.input_size = input_size
        self.output_size = output_size
        self.model_path = model_path
        self.py_input = PythonObject(None) 
        self.py_output = PythonObject(None) 
        self.model = PythonObject(None)  
        self.torch = PythonObject(None) 

        try:
            self.torch = Python.import_module("torch")
            self.py_input = self.torch.zeros(1, self.input_size)
        except e:
            abort("Error importing MLP_Python or torch module: " + String(e))

        self.load_model(self.model_path)

    def load_model(mut self, var model_path: String):
        try:
            self.model = self.torch.jit.load(model_path)
            self.model.eval()
            self.model_path = model_path
        except e:
            abort("Error (re)loading MLP model: " + String(e))

    @always_inline
    def predict_point(mut self, input: List[Float64], mut output: List[Float64]):
        try:

            for i in range(self.input_size):
                self.py_input[0][i] = input[i]
            self.py_output = self.model(self.py_input)  # Run the model with the input

            for i in range(self.output_size):
                var py_val = self.py_output[0][i].item()
                output[i] = py_to_float64(py_val)

        except e:
            abort("Error processing input through MLP: " + String(e))