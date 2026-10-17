/* Isolated Xvfb fixture. Explicit private displays; MIME files never enter argv.
 * Supports real X11 INCR in both directions and bundles of up to three formats. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define LIMIT (128UL*1024*1024+1)
#define CHUNK (32*1024)
struct part { Atom type; unsigned char *data; size_t len; };
struct transfer { Window window; Atom property,target; const struct part *part; size_t offset; };
static long now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000+t.tv_nsec/1000000;}
static int stale_window(Display *d,XErrorEvent *e){(void)d;return e->error_code==BadWindow?0:1;}
static int load(const char *path, struct part *p){
    FILE *f=fopen(path,"rb");if(!f)return 0;
    if(fseek(f,0,SEEK_END)||ftell(f)<0||(unsigned long)ftell(f)>LIMIT){fclose(f);return 0;}
    p->len=ftell(f);rewind(f);p->data=malloc(p->len?p->len:1);
    int ok=p->data&&fread(p->data,1,p->len,f)==p->len;fclose(f);return ok;
}
int main(int argc,char **argv){
    if(argc<3||(strcmp(argv[2],":91")&&strcmp(argv[2],":92")))return 2;
    Display *d=XOpenDisplay(argv[2]);if(!d)return 3;
    XSetErrorHandler(stale_window);
    if(!strcmp(argv[1],"unfocus")){
        Window other=XCreateSimpleWindow(d,DefaultRootWindow(d),0,0,30,30,0,0,0);
        XStoreName(d,other,"Clipboard focus fixture");XMapWindow(d,other);
        XSetInputFocus(d,other,RevertToParent,CurrentTime);XSync(d,False);
        puts("READY");fflush(stdout);
        long until=now_ms()+30000;
        while(now_ms()<until){struct pollfd p={ConnectionNumber(d),POLLIN,0};poll(&p,1,100);while(XPending(d)){XEvent e;XNextEvent(d,&e);}}
        XCloseDisplay(d);return 0;
    }
    if(!strcmp(argv[1],"focus")){
        Window root,parent,*children=NULL;unsigned count=0;int found=0;
        if(XQueryTree(d,DefaultRootWindow(d),&root,&parent,&children,&count)){
            for(unsigned i=0;i<count;i++){char *name=NULL;if(XFetchName(d,children[i],&name)&&name){
                if(!strcmp(name,"FarPane")){XSetInputFocus(d,children[i],RevertToParent,CurrentTime);found=1;}XFree(name);
            }}if(children)XFree(children);
        }XSync(d,False);XCloseDisplay(d);return found?0:4;
    }
    Window w=XCreateSimpleWindow(d,DefaultRootWindow(d),0,0,1,1,0,0,0);
    XSelectInput(d,w,PropertyChangeMask);
    Atom selection=XInternAtom(d,"CLIPBOARD",False),utf8=XInternAtom(d,"UTF8_STRING",False);
    Atom targets=XInternAtom(d,"TARGETS",False),property=XInternAtom(d,"FARPANE_TEST",False),incr=XInternAtom(d,"INCR",False);
    struct part parts[3]={0};int count=0,setting=0,stall=!strcmp(argv[1],"set-stall");FILE *output=stdout;
    if(!strcmp(argv[1],"set")){
        if(argc!=4||strlen(argv[3])>65537)return 5;
        parts[0]=(struct part){utf8,(unsigned char*)argv[3],strlen(argv[3])};count=1;setting=1;
    }else if((!strcmp(argv[1],"set-data")||stall)){
        if(argc<5||argc>9||(argc-3)%2)return 5;
        setting=1;
        for(int i=3;i<argc;i+=2){parts[count].type=XInternAtom(d,argv[i],False);if(!load(argv[i+1],&parts[count]))return 5;count++;}
    }else if(!strcmp(argv[1],"get-data")){
        if(argc!=5)return 5;
        output=fopen(argv[4],"wb");if(!output)return 5;
        utf8=XInternAtom(d,argv[3],False);
    }else if(strcmp(argv[1],"get"))return 2;
    if(setting){
        XSetSelectionOwner(d,selection,w,CurrentTime);XSync(d,False);
        if(XGetSelectionOwner(d,selection)!=w)return 6;
        puts("READY");fflush(stdout);
    }else{XConvertSelection(d,selection,utf8,property,w,CurrentTime);XFlush(d);}
    struct transfer transfers[16]={0};int incremental=0,owned=setting;size_t total=0;
    long deadline=now_ms()+(setting?180000:4000);
    while(now_ms()<deadline){
        if(!XPending(d)){struct pollfd p={ConnectionNumber(d),POLLIN,0};poll(&p,1,30);continue;}
        XEvent e;XNextEvent(d,&e);
        /* A request accepted before ownership changes must still complete. */
        if(setting&&e.type==SelectionClear){fprintf(stderr,"selection-cleared\n");owned=0;}
        if(setting&&!stall&&e.type==PropertyNotify&&e.xproperty.state==PropertyDelete){
            for(int i=0;i<16;i++){
                struct transfer *t=&transfers[i];
                if(!t->part||e.xproperty.window!=t->window||e.xproperty.atom!=t->property)continue;
                size_t n=t->part->len-t->offset;if(n>CHUNK)n=CHUNK;
                XChangeProperty(d,t->window,t->property,t->target,8,PropModeReplace,t->part->data+t->offset,n);
                t->offset+=n;if(!n)t->part=NULL;XFlush(d);
            }
        }
        if(setting&&e.type==SelectionRequest){
            XSelectionRequestEvent *r=&e.xselectionrequest;Atom dest=r->property?r->property:r->target;
            char *name=XGetAtomName(d,r->target);
            fprintf(stderr,"request %s\n",name?name:"unknown");if(name)XFree(name);
            XEvent response={0};response.xselection.type=SelectionNotify;response.xselection.display=d;
            response.xselection.requestor=r->requestor;response.xselection.selection=r->selection;
            response.xselection.target=r->target;response.xselection.time=r->time;response.xselection.property=dest;
            if(r->target==targets){
                Atom formats[5]={targets};int n=1;for(int i=0;i<count;i++)formats[n++]=parts[i].type;
                if(count==1&&parts[0].type==XInternAtom(d,"UTF8_STRING",False))formats[n++]=XA_STRING;
                XChangeProperty(d,r->requestor,dest,XA_ATOM,32,PropModeReplace,(unsigned char*)formats,n);
            }else{
                const struct part *p=NULL;
                for(int i=0;i<count;i++)if(parts[i].type==r->target||(parts[i].type==XInternAtom(d,"UTF8_STRING",False)&&r->target==XA_STRING))p=&parts[i];
                if(!p)response.xselection.property=None;
                else if(!stall&&p->len<=CHUNK)XChangeProperty(d,r->requestor,dest,r->target,8,PropModeReplace,p->data,p->len);
                else{
                    int slot=-1;for(int i=0;i<16;i++)if(!transfers[i].part){slot=i;break;}
                    if(slot<0)response.xselection.property=None;
                    else{
                        transfers[slot]=(struct transfer){r->requestor,dest,r->target,p,0};
                        XSelectInput(d,r->requestor,PropertyChangeMask);unsigned long length=p->len;
                        XChangeProperty(d,r->requestor,dest,incr,32,PropModeReplace,(unsigned char*)&length,1);
                    }
                }
            }
            XSendEvent(d,r->requestor,False,0,&response);XFlush(d);
        }
        if(!setting&&((e.type==SelectionNotify)||(incremental&&e.type==PropertyNotify&&e.xproperty.state==PropertyNewValue&&e.xproperty.atom==property))){
            if(e.type==SelectionNotify&&e.xselection.property==None){fprintf(stderr,"selection-unavailable\n");return 7;}
            Atom actual;int format;unsigned long n,after;unsigned char *bytes=NULL;
            int status=XGetWindowProperty(d,w,property,0,(LIMIT+3)/4,True,AnyPropertyType,&actual,&format,&n,&after,&bytes);
            if(status!=Success||after){fprintf(stderr,"property-error status=%d after=%lu\n",status,after);return 8;}
            if(actual==incr){incremental=1;if(bytes)XFree(bytes);XFlush(d);continue;}
            if(format!=8||total+n>LIMIT){fprintf(stderr,"property-invalid format=%d total=%zu items=%lu\n",format,total,n);return 8;}
            if(fwrite(bytes,1,n,output)!=n)return 8;
            total+=n;if(bytes)XFree(bytes);XFlush(d);
            if(!incremental||n==0){if(output!=stdout)fclose(output);XCloseDisplay(d);return 0;}
        }
        if(setting&&!owned){
            int pending=0;for(int i=0;i<16;i++)if(transfers[i].part)pending=1;
            if(!pending){XCloseDisplay(d);return 0;}
        }
    }fprintf(stderr,"selection-timeout total=%zu incr=%d\n",total,incremental);XCloseDisplay(d);return 9;
}
