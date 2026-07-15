from mmm_python import MMMAudio

MMMAudio.compile(graph_name="WarmTones_Module", package_name="instrument")

mmm = MMMAudio(graph_name="WarmTones_Module", package_name="instrument")

mmm.send_float("warmtones.base_midi", 60.0)