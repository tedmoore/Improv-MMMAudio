from mmm_audio import *

struct InstrumentMatrixMixer(Movable, Copyable):
    var inputs: List[MFloat[2]]
    var input_reaches_output: List[Bool]
    var num_outputs: Int
    var coeffs: List[Float64]
    var reaches_speakers_tmp: List[Bool]
    var output_to_downstream_input: List[Int]  # maps output_idx -> input_idx that receives it (-1 if none/speakers)
    var speaker_output_idx: Int

    def __init__(out self, num_inputs: Int, num_outputs: Int, speaker_output_idx: Int, output_to_downstream_input: List[Int]):
        self.inputs = List[MFloat[2]](length=num_inputs, fill=0.0)
        self.input_reaches_output = List[Bool](length=num_inputs, fill=False)
        self.num_outputs = num_outputs
        self.coeffs = List[Float64](length=self.num_outputs * num_inputs, fill=-130.0)
        self.reaches_speakers_tmp = List[Bool](length=num_inputs, fill=False)
        self.output_to_downstream_input = output_to_downstream_input.copy()
        self.speaker_output_idx = speaker_output_idx

    def provide_input(mut self, index: Int, input: MFloat[2]):
        self.inputs[index] = input
    
    def io_to_idx(self, i: Int, o: Int) -> Int:
        return (o * len(self.inputs)) + i

    def coeff_reaches_output(self, input_idx: Int, output_idx: Int) -> Bool:
        idx: Int = self.io_to_idx(input_idx, output_idx)
        return self.coeffs[idx] > -130.0

    def update_is_used(mut self):
        num_inputs: Int = len(self.inputs)

        # reset all tmp values to false
        for input_idx in range(num_inputs):
            self.reaches_speakers_tmp[input_idx] = False

        # see if each input itself is routed directly to the speaker output
        for input_idx in range(num_inputs):
            if self.coeff_reaches_output(input_idx, self.speaker_output_idx):
                self.reaches_speakers_tmp[input_idx] = True

        # propagate reachability backwards through the graph
        var changed = True
        while changed:
            changed = False
            for input_idx in range(num_inputs):
                if self.reaches_speakers_tmp[input_idx]:
                    continue

                for output_idx in range(self.num_outputs):
                    if output_idx == self.speaker_output_idx:
                        continue  # already handled above
                    
                    if not self.coeff_reaches_output(input_idx, output_idx):
                        continue
                    
                    # check if this output feeds into a downstream input that reaches speakers
                    downstream_input = self.output_to_downstream_input[output_idx]
                    if downstream_input >= 0 and self.reaches_speakers_tmp[downstream_input]:
                        self.reaches_speakers_tmp[input_idx] = True
                        changed = True
                        break

        for input_idx in range(num_inputs):
            self.input_reaches_output[input_idx] = self.reaches_speakers_tmp[input_idx]

        # for i in range(len(self.inputs)):
        #     print(t"Input {i}: {self.input_reaches_output[i]}")

    def get_output(self, output_index: Int) -> MFloat[2]:
        out = MFloat[2](0.0)
        for i in range(len(self.inputs)):
            out += self.inputs[i] * dbamp(self.coeffs[self.io_to_idx(i, output_index)])
        return out

    def get_output_check_used(mut self, o_idx: Int, i_idx: Int) -> Tuple[MFloat[2], Bool]:
        return Tuple[MFloat[2], Bool](self.get_output(o_idx), self.input_reaches_output[i_idx])