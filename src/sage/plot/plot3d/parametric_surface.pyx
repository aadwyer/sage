"""
Graphics 3D object for triangulating surfaces, and a base class for many other objects
that can be represented by a 2d paramaterization.

It takes great care to turn degenerate quadrilaterals into triangles and
to propagate identified points to all attached polygons. This is not
so much to save space as it is to assist the raytracers/other rendering
systems to better understand the surface (and especially calculate correct
surface normals).

AUTHORS:
    -- Robert Bradshaw (2007-08-26): inital version

EXAMPLES:
    sage: from sage.plot.plot3d.parametric_surface import ParametricSurface, MobiusStrip
    sage: S = MobiusStrip(1,.2)
    sage: S.is_enclosed()
    False
    sage: S.show()

NOTE:
    One may override \code{eval()} or \code{eval_c()} in a subclass
    rather than passing in a function for greater speed.
    One also would want to override get_grid.

TODO: actually remove unused points, fix the below code

    S = ParametricSurface(f=(lambda (x,y):(x,y,0)), domain=(range(10),range(10)))

"""


#*****************************************************************************
#      Copyright (C) 2007 Robert Bradshaw <robertwb@math.washington.edu>
#
#  Distributed under the terms of the GNU General Public License (GPL)
#
#    This code is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#    General Public License for more details.
#
#  The full text of the GPL is available at:
#
#                  http://www.gnu.org/licenses/
#*****************************************************************************



include "../../ext/stdsage.pxi"
include "../../ext/interrupt.pxi"

include "point_c.pxi"

from math import cos, sin
from sage.rings.all import RDF



cdef inline bint smash_edge(point_c* vs, face_c* f, int a, int b):
    if point_c_eq(vs[f.vertices[a]], vs[f.vertices[b]]):
        f.vertices[b] = f.vertices[a]
        f.n = 3
        return 1
    else:
        return 0

cdef class ParametricSurface(IndexFaceSet):

    """
    EXAMPLES:
        sage: from sage.plot.plot3d.parametric_surface import ParametricSurface
        sage: def f(x,y): return cos(x)*sin(y), sin(x)*sin(y), cos(y)+log(tan(y/2))+0.2*x
        sage: S = ParametricSurface(f, (srange(0,12.4,0.1), srange(0.1,2,0.1)))
        sage: show(S)

        sage: len(S.face_list())
        2214
    """

    def __init__(self, f=None, domain=None, **kwds):
        self.f = f
        self.render_grid = domain
        IndexFaceSet.__init__(self, [], [], **kwds)

    def tachyon_repr(self, render_params):
        self.triangulate(render_params)
        return IndexFaceSet.tachyon_repr(self, render_params)

    def obj_repr(self, render_params):
        self.triangulate(render_params)
        return IndexFaceSet.obj_repr(self, render_params)

    def is_enclosed(self):
        """
        Whether or not it is necessary to render the back sides of the polygons
        (assuming, of course, that they have the correct orientation).

        This is calculated in by verifying the opposite edges
        of the rendered domain either line up or are pinched together.

        EXAMPLES:
            sage: from sage.plot.plot3d.shapes import *
            sage: Sphere(1).is_enclosed()
            True

            sage: from sage.plot.plot3d.parametric_surface import MobiusStrip
            sage: MobiusStrip(1,0.2).is_enclosed()
            False
        """
        if self.fcount == 0:
            self.triangulate()
        return self.enclosed

    def dual(self):
        # This doesn't completely make sense...
        if self.fcount == 0:
            self.triangulate()
        return IndexFaceSet.dual(self)

    def triangulate(self, render_params=None):
        """
        Call self.eval() for all (u,v) in urange \times vrange
        to construct this surface.

        The most complicated part of this code is identifying shared
        vertices and shrinking trivial edges. This is not done so much
        to save memory, rather it is needed so normals of the triangles
        can be calculated correctly.
        """
        if render_params is None:
            render_params = self.default_render_params()
        ds = render_params.ds
        if render_params.transform is not None:
            ds /= render_params.transform.max_scale()
        urange, vrange = self.get_grid(ds)
        urange = [float(u) for u in urange]
        vrange = [float(v) for v in vrange]
        if self.render_grid == (urange, vrange) and self.fcount != 0:
            # Already triangulated at on this grid.
            return

        cdef Py_ssize_t i, j
        cdef Py_ssize_t n = len(urange) - 1
        cdef Py_ssize_t m = len(vrange) - 1
        cdef double u, v
        cdef Py_ssize_t ix = 0

        _sig_on
        try:
            self.realloc((m+1)*(n+1), m*n, 4*m*n)
            for u in urange:
                for v in vrange:
                    self.eval_c(&self.vs[ix], u, v)
                    ix += 1
        except:
            _sig_off
            self.fcount = self.vcount = 0
            self.render_grid = None
            raise

        # face_c.vertices:
        #
        #   0 - 1
        #   |   |
        #   3 - 2

        cdef face_c *face, *last_face

        for i from 0 <= i < n:
            for j from 0 <= j < m:
                ix = i*m+j
                face = &self._faces[ix]
                face.n = 4
                face.vertices = &self.face_indices[4*ix]

                # Connect to the i-1 row
                if i == 0:
                    if j == 0:
                        face.vertices[0] = 0
                    else:
                        face.vertices[0] = self._faces[ix-1].vertices[1]
                    face.vertices[1] = j+1
                    smash_edge(self.vs, face, 0, 1)
                else:
                    face.vertices[0] = self._faces[ix-m].vertices[3]
                    face.vertices[1] = self._faces[ix-m].vertices[2]

                # Connect to the j-1 col
                if j == 0:
                    face.vertices[3] = (i+1)*(m+1)
                    smash_edge(self.vs, face, 0, 3)
                else:
                    face.vertices[3] = self._faces[ix-1].vertices[2]

                # This is the newly-seen vertex, identify if its a triangle
                face.vertices[2] = (i+1)*(m+1)+j+1
                smash_edge(self.vs, face, 1, 2) or smash_edge(self.vs, face, 3, 2)

        # Now we see if it wraps around or is otherwise enclosed
        cdef bint enclosed = 1

        cdef face_c *first, *last
        for j from 0 <= j < m:
            first = &self._faces[j]
            last  = &self._faces[(n-1)*m+j]
            if point_c_eq(self.vs[first.vertices[0]], self.vs[last.vertices[3]]):
                last.vertices[3] = first.vertices[0]
            elif first.vertices[0] != first.vertices[1] or last.vertices[3] != last.vertices[2]:
                enclosed = 0
            if point_c_eq(self.vs[first.vertices[1]], self.vs[last.vertices[2]]):
                last.vertices[2] = first.vertices[1]
            elif first.vertices[0] != first.vertices[1] or last.vertices[3] != last.vertices[2]:
                enclosed = 0

        for i from 0 <= i < n:
            first = &self._faces[i*m]
            last  = &self._faces[i*m + m-1]
            if point_c_eq(self.vs[first.vertices[0]], self.vs[last.vertices[1]]):
                last.vertices[1] = first.vertices[0]
            elif first.vertices[0] != first.vertices[3] or last.vertices[1] != last.vertices[2]:
                enclosed = 0
            if point_c_eq(self.vs[first.vertices[3]], self.vs[last.vertices[2]]):
                last.vertices[2] = first.vertices[3]
            elif first.vertices[0] != first.vertices[3] or last.vertices[1] != last.vertices[2]:
                enclosed = 0

        self.enclosed = enclosed

        # make sure we deleted the correct point from the triangles
        for ix from 0 <= ix < n*m:
            face = &self._faces[ix]
            if face.n == 3:
                if face.vertices[3] == face.vertices[2] or face.vertices[3] == face.vertices[0]:
                    pass
                else:
                    if face.vertices[0] == face.vertices[1]:
                        face.vertices[1] = face.vertices[2]
                    # face.vertices[1] == face.vertices[2]
                    face.vertices[2] = face.vertices[3]

        _sig_off

        self.vcount = (n+1)*(m+1)
        self.fcount = n*m
        self.icount = 4*n*m
        self._clean_point_list()

        self.render_grid = urange, vrange


    def get_grid(self, ds):
        if self.render_grid is None:
            raise NotImplementedError, "You must override the get_grid method."
        return self.render_grid

    cdef eval_c(self, point_c *res, double u, double v):
        p = self.eval(u, v)
        res.x, res.y, res.z = tuple(p)

    def eval(self, u, v):
        if self.f is None:
            raise NotImplementedError
        else:
            return self.f(u,v)


class MobiusStrip(ParametricSurface):
    def __init__(self, r, width, twists=1, **kwds):
        ParametricSurface.__init__(self, **kwds)
        self.r = float(r)
        self.width = float(width)
        self.twists = int(twists)
    def get_grid(self, ds):
        twoPi = RDF.pi()*2
        res = max(min(twoPi*(self.r+self.twists*self.width)/ds, 10), 6*self.twists, 50)
        return [-1,1],[twoPi*k/res for k in range(res)] + [0]
    def eval(self, u, v):
        return ( (self.r + u*self.width*cos(self.twists*v/2)) * cos(v),
                 (self.r + u*self.width*cos(self.twists*v/2)) * sin(v),
                 u*self.width*sin(self.twists*v/2) )

