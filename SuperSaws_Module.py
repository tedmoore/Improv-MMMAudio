from mmm_python import MMMAudio

MMMAudio.compile(graph_name="SuperSaws_Module", package_name="instrument")

mmm = MMMAudio(graph_name="SuperSaws_Module", package_name="instrument")

mmm.send_float("SuperSaws.base_midi", 60.0)