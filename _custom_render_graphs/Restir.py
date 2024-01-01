from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_Restir():
    g = RenderGraph('Restir')
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('Restir', 'Restir', {})
    g.add_edge('VBufferRT.vbuffer', 'Restir.vbuffer')
    g.mark_output('Restir.color')
    return g

Restir = render_graph_Restir()
try: m.addGraph(Restir)
except NameError: None
