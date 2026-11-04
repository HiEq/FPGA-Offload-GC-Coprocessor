// FOGCCC DMA build helper.
//
// Exposes a coherent 256 KiB staging buffer and one ioctl that copies it to a
// caller-supplied physical address with the Zynq PS DMA controller (PL330).
// The staging buffer is mmap'ed by userspace; the graph is laid out there and
// then copied to the FPGA graph DDR window in one DMA transaction.
#include <linux/module.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/completion.h>
#include <linux/mutex.h>
#include <linux/ioctl.h>

#define DEV_NAME "fogccc_dma"
#define BUF_SIZE (256u * 1024u)

struct fogccc_dma_info {
    __u32 size;
    __u32 src_phys;
    __u32 dst_phys;
};

struct fogccc_dma_copy {
    __u32 dst_phys;
    __u32 len;
};

#define FOGCCC_DMA_IOC_MAGIC 'F'
#define FOGCCC_DMA_IOC_INFO _IOR(FOGCCC_DMA_IOC_MAGIC, 0, struct fogccc_dma_info)
#define FOGCCC_DMA_IOC_COPY _IOW(FOGCCC_DMA_IOC_MAGIC, 1, struct fogccc_dma_copy)

struct fogccc_dma_dev {
    struct dma_chan *chan;
    void *cpu_addr;
    dma_addr_t dma_handle;
    size_t size;
    struct completion done;
    struct mutex lock;
    dev_t devno;
    struct cdev cdev;
    struct class *cls;
    struct device *dev;
};

static struct fogccc_dma_dev *gdev;

static void fogccc_dma_callback(void *arg)
{
    complete((struct completion *)arg);
}

static int fogccc_dma_open(struct inode *inode, struct file *filp)
{
    filp->private_data = gdev;
    return 0;
}

static int fogccc_dma_release(struct inode *inode, struct file *filp)
{
    return 0;
}

static long fogccc_dma_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct fogccc_dma_dev *d = filp->private_data;
    struct fogccc_dma_info info;
    struct fogccc_dma_copy cp;
    struct dma_async_tx_descriptor *tx;
    dma_cookie_t cookie;
    unsigned long left;

    switch (cmd) {
    case FOGCCC_DMA_IOC_INFO:
        info.size = (__u32)d->size;
        info.src_phys = (__u32)d->dma_handle;
        info.dst_phys = 0x1E000000u;
        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        return 0;

    case FOGCCC_DMA_IOC_COPY:
        if (copy_from_user(&cp, (void __user *)arg, sizeof(cp)))
            return -EFAULT;
        if (!cp.len || cp.len > d->size || (cp.dst_phys & 3) || (cp.len & 3))
            return -EINVAL;

        if (mutex_lock_interruptible(&d->lock))
            return -ERESTARTSYS;
        reinit_completion(&d->done);
        tx = dmaengine_prep_dma_memcpy(d->chan, (dma_addr_t)cp.dst_phys,
                                       d->dma_handle, cp.len,
                                       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
        if (!tx) {
            mutex_unlock(&d->lock);
            return -EIO;
        }
        tx->callback = fogccc_dma_callback;
        tx->callback_param = &d->done;
        cookie = dmaengine_submit(tx);
        if (dma_submit_error(cookie)) {
            mutex_unlock(&d->lock);
            return -EIO;
        }
        dma_async_issue_pending(d->chan);
        left = wait_for_completion_timeout(&d->done, msecs_to_jiffies(2000));
        mutex_unlock(&d->lock);
        if (!left)
            return -ETIMEDOUT;
        return 0;

    default:
        return -ENOTTY;
    }
}

static int fogccc_dma_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct fogccc_dma_dev *d = filp->private_data;
    unsigned long len = vma->vm_end - vma->vm_start;

    if (vma->vm_pgoff || len > d->size)
        return -EINVAL;
    return dma_mmap_attrs(d->chan->device->dev, vma, d->cpu_addr,
                          d->dma_handle, len, 0);
}

static const struct file_operations fogccc_dma_fops = {
    .owner = THIS_MODULE,
    .open = fogccc_dma_open,
    .release = fogccc_dma_release,
    .unlocked_ioctl = fogccc_dma_ioctl,
    .mmap = fogccc_dma_mmap,
};

static int __init fogccc_dma_init(void)
{
    int ret;

    gdev = kzalloc(sizeof(*gdev), GFP_KERNEL);
    if (!gdev)
        return -ENOMEM;

    gdev->size = BUF_SIZE;
    mutex_init(&gdev->lock);
    init_completion(&gdev->done);

    dma_cap_mask_t mask;

    dma_cap_zero(mask);
    dma_cap_set(DMA_MEMCPY, mask);
    gdev->chan = dma_request_chan_by_mask(&mask);
    if (IS_ERR(gdev->chan)) {
        ret = PTR_ERR(gdev->chan);
        pr_err("fogccc_dma: no memcpy DMA channel (%d)\n", ret);
        kfree(gdev);
        gdev = NULL;
        return ret;
    }

    gdev->cpu_addr = dma_alloc_attrs(gdev->chan->device->dev, gdev->size,
                                     &gdev->dma_handle, GFP_KERNEL, 0);
    if (!gdev->cpu_addr) {
        pr_err("fogccc_dma: dma_alloc_attrs(%u) failed\n", gdev->size);
        dma_release_channel(gdev->chan);
        kfree(gdev);
        gdev = NULL;
        return -ENOMEM;
    }

    ret = alloc_chrdev_region(&gdev->devno, 0, 1, DEV_NAME);
    if (ret)
        goto err_dma;

    cdev_init(&gdev->cdev, &fogccc_dma_fops);
    gdev->cdev.owner = THIS_MODULE;
    ret = cdev_add(&gdev->cdev, gdev->devno, 1);
    if (ret)
        goto err_region;

    gdev->cls = class_create(DEV_NAME);
    if (IS_ERR(gdev->cls)) {
        ret = PTR_ERR(gdev->cls);
        goto err_cdev;
    }
    gdev->dev = device_create(gdev->cls, NULL, gdev->devno, NULL, DEV_NAME);
    if (IS_ERR(gdev->dev)) {
        ret = PTR_ERR(gdev->dev);
        goto err_class;
    }

    pr_info("fogccc_dma: ready size=%u src_phys=0x%x dev=%s\n",
            gdev->size, (unsigned)gdev->dma_handle, DEV_NAME);
    return 0;

err_class:
    class_destroy(gdev->cls);
err_cdev:
    cdev_del(&gdev->cdev);
err_region:
    unregister_chrdev_region(gdev->devno, 1);
err_dma:
    dma_free_attrs(gdev->chan->device->dev, gdev->size, gdev->cpu_addr,
                   gdev->dma_handle, 0);
    dma_release_channel(gdev->chan);
    kfree(gdev);
    gdev = NULL;
    return ret;
}

static void __exit fogccc_dma_exit(void)
{
    if (!gdev)
        return;
    device_destroy(gdev->cls, gdev->devno);
    class_destroy(gdev->cls);
    cdev_del(&gdev->cdev);
    unregister_chrdev_region(gdev->devno, 1);
    dma_free_attrs(gdev->chan->device->dev, gdev->size, gdev->cpu_addr,
                   gdev->dma_handle, 0);
    dma_release_channel(gdev->chan);
    kfree(gdev);
    gdev = NULL;
}

module_init(fogccc_dma_init);
module_exit(fogccc_dma_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("FOGCCC graph build DMA staging buffer");
